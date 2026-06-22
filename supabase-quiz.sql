-- Онлайн-викторина Beta 2
-- Выполните в том же проекте Supabase: SQL Editor → New query → Run.

create extension if not exists pgcrypto;

create table if not exists public.quiz_sets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  subject_id text default '',
  subject_name text default '',
  group_id text default '',
  group_name text default '',
  course text default '',
  lesson_date date,
  topic text default '',
  seconds_per_question integer not null default 20 check (seconds_per_question between 5 and 300),
  speed_bonus boolean not null default true,
  auto_advance boolean not null default true,
  reveal_seconds integer not null default 5 check (reveal_seconds between 1 and 60),
  leaderboard_mode text not null default 'after_question' check (leaderboard_mode in ('after_answer','after_question','final')),
  total_points integer not null default 100 check (total_points between 1 and 100000),
  source_question_count integer not null default 0,
  selected_question_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.quiz_questions (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quiz_sets(id) on delete cascade,
  position integer not null,
  question_text text not null,
  options jsonb not null,
  correct_answers jsonb not null,
  explanation text default '',
  points integer not null default 1000 check (points between 1 and 100000)
);

create table if not exists public.quiz_rooms (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quiz_sets(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  code text not null unique check (code ~ '^[0-9]{6}$'),
  status text not null default 'lobby' check (status in ('lobby','question','reveal','finished','closed')),
  current_position integer not null default 0,
  question_started_at timestamptz,
  question_ends_at timestamptz,
  reveal_ends_at timestamptz,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

-- Эти команды безопасно обновляют уже созданные таблицы.
alter table public.quiz_sets add column if not exists auto_advance boolean not null default true;
alter table public.quiz_sets add column if not exists reveal_seconds integer not null default 5;
alter table public.quiz_sets add column if not exists leaderboard_mode text not null default 'after_question';
alter table public.quiz_sets add column if not exists total_points integer not null default 100;
alter table public.quiz_sets add column if not exists source_question_count integer not null default 0;
alter table public.quiz_sets add column if not exists selected_question_count integer not null default 0;
alter table public.quiz_rooms add column if not exists reveal_ends_at timestamptz;

create table if not exists public.quiz_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  student_id text,
  player_name text not null,
  reconnect_token uuid not null unique default gen_random_uuid(),
  active boolean not null default true,
  joined_at timestamptz not null default now(),
  unique(room_id,student_id)
);

create table if not exists public.quiz_answers (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  player_id uuid not null references public.quiz_players(id) on delete cascade,
  question_id uuid not null references public.quiz_questions(id) on delete cascade,
  selected_answers jsonb not null default '[]'::jsonb,
  correct boolean not null default false,
  response_ms integer not null default 0,
  awarded_points integer not null default 0,
  answered_at timestamptz not null default now(),
  unique(player_id,question_id)
);

create index if not exists quiz_questions_quiz_idx on public.quiz_questions(quiz_id,position);
create index if not exists quiz_rooms_owner_idx on public.quiz_rooms(owner_id,created_at desc);
create index if not exists quiz_players_room_idx on public.quiz_players(room_id);
create index if not exists quiz_answers_room_idx on public.quiz_answers(room_id);

alter table public.quiz_sets enable row level security;
alter table public.quiz_questions enable row level security;
alter table public.quiz_rooms enable row level security;
alter table public.quiz_players enable row level security;
alter table public.quiz_answers enable row level security;

grant select,insert,update,delete on public.quiz_sets to authenticated;
grant select,insert,update,delete on public.quiz_questions to authenticated;
grant select,insert,update,delete on public.quiz_rooms to authenticated;
grant select,insert,update,delete on public.quiz_players to authenticated;
grant select,delete on public.quiz_answers to authenticated;

drop policy if exists "Teacher manages quiz sets" on public.quiz_sets;
create policy "Teacher manages quiz sets" on public.quiz_sets for all to authenticated
using (owner_id=auth.uid()) with check (owner_id=auth.uid());

drop policy if exists "Teacher manages quiz questions" on public.quiz_questions;
create policy "Teacher manages quiz questions" on public.quiz_questions for all to authenticated
using (exists(select 1 from public.quiz_sets q where q.id=quiz_id and q.owner_id=auth.uid()))
with check (exists(select 1 from public.quiz_sets q where q.id=quiz_id and q.owner_id=auth.uid()));

drop policy if exists "Teacher manages quiz rooms" on public.quiz_rooms;
create policy "Teacher manages quiz rooms" on public.quiz_rooms for all to authenticated
using (owner_id=auth.uid()) with check (owner_id=auth.uid());

drop policy if exists "Teacher reads quiz players" on public.quiz_players;
create policy "Teacher reads quiz players" on public.quiz_players for select to authenticated
using (exists(select 1 from public.quiz_rooms r where r.id=room_id and r.owner_id=auth.uid()));

drop policy if exists "Teacher creates quiz players" on public.quiz_players;
create policy "Teacher creates quiz players" on public.quiz_players for insert to authenticated
with check (exists(select 1 from public.quiz_rooms r where r.id=room_id and r.owner_id=auth.uid()));

drop policy if exists "Teacher updates quiz players" on public.quiz_players;
create policy "Teacher updates quiz players" on public.quiz_players for update to authenticated
using (exists(select 1 from public.quiz_rooms r where r.id=room_id and r.owner_id=auth.uid()));

drop policy if exists "Teacher deletes quiz players" on public.quiz_players;
create policy "Teacher deletes quiz players" on public.quiz_players for delete to authenticated
using (exists(select 1 from public.quiz_rooms r where r.id=room_id and r.owner_id=auth.uid()));

drop policy if exists "Teacher reads quiz answers" on public.quiz_answers;
create policy "Teacher reads quiz answers" on public.quiz_answers for select to authenticated
using (exists(select 1 from public.quiz_rooms r where r.id=room_id and r.owner_id=auth.uid()));

drop policy if exists "Teacher deletes quiz answers" on public.quiz_answers;
create policy "Teacher deletes quiz answers" on public.quiz_answers for delete to authenticated
using (exists(select 1 from public.quiz_rooms r where r.id=room_id and r.owner_id=auth.uid()));

create or replace function public.quiz_join(p_code text,p_student_id text,p_name text,p_reconnect uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.quiz_rooms; p public.quiz_players;
begin
  select * into r from public.quiz_rooms where code=trim(p_code) and status not in ('finished','closed');
  if r.id is null then raise exception 'Комната не найдена или уже закрыта'; end if;
  if p_reconnect is not null then
    select * into p from public.quiz_players where room_id=r.id and reconnect_token=p_reconnect;
  end if;
  if p.id is null and coalesce(trim(p_student_id),'')<>'' then
    select * into p from public.quiz_players where room_id=r.id and student_id=trim(p_student_id);
  end if;
  if p.id is null then
    insert into public.quiz_players(room_id,student_id,player_name)
    values(r.id,nullif(trim(p_student_id),''),left(trim(p_name),100)) returning * into p;
  else
    update public.quiz_players set player_name=left(trim(p_name),100),active=true where id=p.id returning * into p;
  end if;
  return jsonb_build_object('room_id',r.id,'player_id',p.id,'token',p.reconnect_token,'name',p.player_name);
end $$;

create or replace function public.quiz_roster(p_code text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.quiz_rooms;
begin
  select * into r from public.quiz_rooms where code=trim(p_code) and status not in ('finished','closed');
  if r.id is null then raise exception 'Комната не найдена или уже закрыта'; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'student_id',student_id,'name',player_name,'joined',active
    ) order by player_name),'[]'::jsonb)
    from public.quiz_players where room_id=r.id and student_id is not null
  );
end $$;

create or replace function public.quiz_state(p_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.quiz_players; r public.quiz_rooms; s public.quiz_sets; q public.quiz_questions;
declare answered boolean:=false; answer_count integer:=0; total_players integer:=0; my_points integer:=0;
begin
  select * into p from public.quiz_players where reconnect_token=p_token and active=true;
  if p.id is null then raise exception 'Участник не найден'; end if;
  select * into r from public.quiz_rooms where id=p.room_id;
  select * into s from public.quiz_sets where id=r.quiz_id;
  select count(*) into total_players from public.quiz_players where room_id=r.id and active=true;
  select coalesce(sum(awarded_points),0) into my_points from public.quiz_answers where player_id=p.id;
  if r.current_position>0 then
    select * into q from public.quiz_questions where quiz_id=s.id and position=r.current_position;
    select exists(select 1 from public.quiz_answers where player_id=p.id and question_id=q.id) into answered;
    select count(*) into answer_count from public.quiz_answers where room_id=r.id and question_id=q.id;
  end if;
  return jsonb_build_object(
    'room_id',r.id,'quiz_title',s.title,'topic',s.topic,'status',r.status,
    'position',r.current_position,'question_ends_at',r.question_ends_at,'reveal_ends_at',r.reveal_ends_at,
    'leaderboard_mode',s.leaderboard_mode,
    'player_name',p.player_name,'my_points',my_points,'answered',answered,
    'answer_count',answer_count,'player_count',total_players,
    'question',case when q.id is null then null else jsonb_build_object(
      'id',q.id,'text',q.question_text,'options',q.options,
      'correct',case when r.status in ('reveal','finished') then q.correct_answers else null end,
      'explanation',case when r.status in ('reveal','finished') then q.explanation else '' end
    ) end,
    'leaders',case when r.status='finished'
      or (s.leaderboard_mode='after_question' and r.status='reveal')
      or (s.leaderboard_mode='after_answer' and r.status in ('question','reveal')) then (
      select coalesce(jsonb_agg(jsonb_build_object('name',x.player_name,'points',x.points,'rank',x.rank)),'[]'::jsonb)
      from (
        select pl.player_name,coalesce(sum(a.awarded_points),0)::integer points,
          dense_rank() over(order by coalesce(sum(a.awarded_points),0) desc)::integer rank
        from public.quiz_players pl left join public.quiz_answers a on a.player_id=pl.id
        where pl.room_id=r.id and pl.active=true group by pl.id order by points desc,pl.joined_at limit 10
      ) x
    ) else '[]'::jsonb end
  );
end $$;

create or replace function public.quiz_answer(p_token uuid,p_question uuid,p_answers jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.quiz_players; r public.quiz_rooms; s public.quiz_sets; q public.quiz_questions;
declare elapsed integer; earned integer:=0; is_correct boolean:=false;
begin
  select * into p from public.quiz_players where reconnect_token=p_token and active=true;
  if p.id is null then raise exception 'Участник не найден'; end if;
  select * into r from public.quiz_rooms where id=p.room_id for update;
  if r.status<>'question' or now()>r.question_ends_at then raise exception 'Время ответа завершено'; end if;
  select * into q from public.quiz_questions where id=p_question and quiz_id=r.quiz_id and position=r.current_position;
  if q.id is null then raise exception 'Вопрос не найден'; end if;
  select * into s from public.quiz_sets where id=r.quiz_id;
  is_correct:=coalesce(p_answers,'[]'::jsonb)=q.correct_answers;
  elapsed:=greatest(0,extract(epoch from (now()-r.question_started_at))*1000)::integer;
  if is_correct then
    earned:=q.points;
    if s.speed_bonus then
      earned:=round(q.points*(0.5+0.5*greatest(0,1.0-elapsed/greatest(1000,s.seconds_per_question*1000))))::integer;
    end if;
  end if;
  insert into public.quiz_answers(room_id,player_id,question_id,selected_answers,correct,response_ms,awarded_points)
  values(r.id,p.id,q.id,coalesce(p_answers,'[]'::jsonb),is_correct,elapsed,earned)
  on conflict(player_id,question_id) do nothing;
  return jsonb_build_object('accepted',true,'points',earned);
end $$;

grant execute on function public.quiz_join(text,text,text,uuid) to anon,authenticated;
grant execute on function public.quiz_roster(text) to anon,authenticated;
grant execute on function public.quiz_state(uuid) to anon,authenticated;
grant execute on function public.quiz_answer(uuid,uuid,jsonb) to anon,authenticated;
