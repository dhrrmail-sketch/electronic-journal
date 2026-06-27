-- Модуль тестирования 2.0.0 Beta 66
-- Выполните этот файл один раз: Supabase → SQL Editor → New query → Run.

create extension if not exists pgcrypto;

-- Beta 66: канонизация набора ответов (убирает дубли и пустые значения, сортирует).
-- Нужна, чтобы оценка не зависела от порядка вариантов, присланных клиентом.
create or replace function public.normalize_answer(p jsonb)
returns jsonb language sql immutable as $$
  select coalesce(
    (select jsonb_agg(value order by value)
     from (
       select distinct value
       from jsonb_array_elements_text(
         case when jsonb_typeof(coalesce(p,'[]'::jsonb))='array' then p else '[]'::jsonb end
       )
       where value <> ''
     ) s),
    '[]'::jsonb
  );
$$;

-- Beta 66: единый расчет балла за один вопрос — сервер единственный источник правды по оценке.
-- Используется и при сдаче, и в разборе, чтобы цифры не расходились.
create or replace function public.score_answer(p_type text, p_scoring text, p_selected jsonb, p_correct jsonb, p_points numeric)
returns numeric language plpgsql immutable as $$
declare
  cor jsonb:=public.normalize_answer(p_correct);
  sel jsonb:=public.normalize_answer(p_selected);
  hits int; wrong int; total int; share numeric;
begin
  if p_type='MULTIPLE' and p_scoring='partial' then
    -- Частичный балл = (верно выбранные - лишние) / число правильных, не ниже нуля.
    total:=jsonb_array_length(cor);
    if total=0 then return 0; end if;
    select count(*) into hits from jsonb_array_elements_text(sel) s
      where exists (select 1 from jsonb_array_elements_text(cor) c where c.value=s.value);
    select count(*) into wrong from jsonb_array_elements_text(sel) s
      where not exists (select 1 from jsonb_array_elements_text(cor) c where c.value=s.value);
    share:=greatest(0,(hits-wrong)::numeric/total);
    return round(p_points*share,2);
  end if;
  -- Одиночные и «все или ничего»: сравнение целиком по нормализованным множествам.
  if sel=cor then return p_points; end if;
  return 0;
end $$;

create table if not exists public.tests (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  topic text default '',
  seminar_number text default '',
  assigned_group_id text default '',
  assigned_group_name text default '',
  assigned_course text default '',
  assigned_subject_id text default '',
  assigned_subject_name text default '',
  instructions text default '',
  duration_minutes integer not null default 30 check (duration_minutes between 1 and 300),
  opens_at timestamptz not null,
  deadline_at timestamptz not null,
  max_attempts integer not null default 1 check (max_attempts between 1 and 10),
  randomize_questions boolean not null default false,
  question_limit integer,
  reveal_mode text not null default 'after_deadline'
    check (reveal_mode in ('after_submit','after_deadline','never')),
  status text not null default 'draft' check (status in ('draft','published','closed')),
  journal_date date,
  journal_criterion_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (deadline_at > opens_at)
);

alter table public.tests add column if not exists seminar_number text default '';
alter table public.tests add column if not exists assigned_group_id text default '';
alter table public.tests add column if not exists assigned_group_name text default '';
alter table public.tests add column if not exists assigned_course text default '';
alter table public.tests add column if not exists assigned_subject_id text default '';
alter table public.tests add column if not exists assigned_subject_name text default '';

create table if not exists public.test_questions (
  id uuid primary key default gen_random_uuid(),
  test_id uuid not null references public.tests(id) on delete cascade,
  position integer not null,
  type text not null check (type in ('SINGLE','MULTIPLE','TRUE_FALSE')),
  question_text text not null,
  options jsonb not null,
  correct_answers jsonb not null,
  points numeric(8,2) not null default 1 check (points > 0),
  explanation text default ''
);

-- Beta 66: режим начисления баллов за вопрос.
-- 'all_or_nothing' — прежнее поведение: балл только за полностью верный ответ.
-- 'partial' — частичный балл для вопросов с несколькими ответами (тип MULTIPLE).
alter table public.test_questions
  add column if not exists scoring text not null default 'all_or_nothing'
  check (scoring in ('all_or_nothing','partial'));

create table if not exists public.test_invitations (
  id uuid primary key default gen_random_uuid(),
  test_id uuid not null references public.tests(id) on delete cascade,
  student_id text,
  student_name text not null,
  student_email text not null,
  token uuid not null unique default gen_random_uuid(),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

-- Beta 21: назначение определяется студентом, а не email.
-- Это позволяет нескольким студентам временно использовать один адрес почты.
alter table public.test_invitations
  drop constraint if exists test_invitations_test_id_student_email_key;

create index if not exists test_invitations_test_student_idx
  on public.test_invitations(test_id,student_id);

create table if not exists public.test_attempts (
  id uuid primary key default gen_random_uuid(),
  test_id uuid not null references public.tests(id) on delete cascade,
  invitation_id uuid not null references public.test_invitations(id) on delete cascade,
  attempt_no integer not null,
  question_ids jsonb not null default '[]'::jsonb,
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  submitted_at timestamptz,
  answers jsonb not null default '{}'::jsonb,
  score numeric(10,2),
  max_score numeric(10,2),
  status text not null default 'in_progress'
    check (status in ('in_progress','submitted','expired')),
  unique(invitation_id, attempt_no)
);

create index if not exists test_questions_test_id_idx on public.test_questions(test_id);
create index if not exists test_invitations_test_id_idx on public.test_invitations(test_id);
create index if not exists test_attempts_test_id_idx on public.test_attempts(test_id);
create index if not exists test_attempts_invitation_id_idx on public.test_attempts(invitation_id);

alter table public.tests enable row level security;
alter table public.test_questions enable row level security;
alter table public.test_invitations enable row level security;
alter table public.test_attempts enable row level security;

grant select,insert,update,delete on public.tests to authenticated;
grant select,insert,update,delete on public.test_questions to authenticated;
grant select,insert,update,delete on public.test_invitations to authenticated;
grant select on public.test_attempts to authenticated;

drop policy if exists "Teacher manages own tests" on public.tests;
create policy "Teacher manages own tests" on public.tests
for all to authenticated
using (owner_id = auth.uid())
with check (owner_id = auth.uid());

drop policy if exists "Teacher manages own questions" on public.test_questions;
create policy "Teacher manages own questions" on public.test_questions
for all to authenticated
using (exists(select 1 from public.tests t where t.id=test_id and t.owner_id=auth.uid()))
with check (exists(select 1 from public.tests t where t.id=test_id and t.owner_id=auth.uid()));

drop policy if exists "Teacher manages own invitations" on public.test_invitations;
create policy "Teacher manages own invitations" on public.test_invitations
for all to authenticated
using (exists(select 1 from public.tests t where t.id=test_id and t.owner_id=auth.uid()))
with check (exists(select 1 from public.tests t where t.id=test_id and t.owner_id=auth.uid()));

drop policy if exists "Teacher reads own attempts" on public.test_attempts;
create policy "Teacher reads own attempts" on public.test_attempts
for select to authenticated
using (exists(select 1 from public.tests t where t.id=test_id and t.owner_id=auth.uid()));

create or replace function public.test_invitation_info(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.test_invitations;
  tst public.tests;
  attempts_used integer;
begin
  select * into inv from public.test_invitations where token=p_token;
  if inv.id is null then raise exception 'Ссылка недействительна'; end if;
  select * into tst from public.tests where id=inv.test_id;
  select count(*) into attempts_used from public.test_attempts where invitation_id=inv.id;
  return jsonb_build_object(
    'student_name',inv.student_name,'title',tst.title,'topic',tst.topic,
    'instructions',tst.instructions,'duration_minutes',tst.duration_minutes,
    'opens_at',tst.opens_at,'deadline_at',tst.deadline_at,'status',tst.status,
    'max_attempts',tst.max_attempts,'attempts_used',attempts_used
  );
end $$;

create or replace function public.start_test_attempt(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.test_invitations;
  tst public.tests;
  att public.test_attempts;
  ids jsonb;
  used integer;
begin
  select * into inv from public.test_invitations where token=p_token;
  if inv.id is null then raise exception 'Ссылка недействительна'; end if;
  select * into tst from public.tests where id=inv.test_id;
  if tst.status <> 'published' then raise exception 'Тест пока закрыт'; end if;
  if now() < tst.opens_at then raise exception 'Тест ещё не открыт'; end if;
  if now() > tst.deadline_at then raise exception 'Срок прохождения теста истёк'; end if;

  select * into att from public.test_attempts
  where invitation_id=inv.id and status='in_progress' and expires_at>now()
  order by started_at desc limit 1;

  if att.id is null then
    update public.test_attempts set status='expired'
      where invitation_id=inv.id and status='in_progress' and expires_at<=now();
    select count(*) into used from public.test_attempts where invitation_id=inv.id;
    if used >= tst.max_attempts then raise exception 'Все попытки уже использованы'; end if;
    select coalesce(jsonb_agg(id::text),'[]'::jsonb) into ids
    from (
      select id from public.test_questions where test_id=tst.id
      order by case when tst.randomize_questions then random() else position::double precision end
      limit coalesce(tst.question_limit,2147483647)
    ) selected;
    insert into public.test_attempts(test_id,invitation_id,attempt_no,question_ids,expires_at)
    values(tst.id,inv.id,used+1,ids,least(tst.deadline_at,now()+make_interval(mins=>tst.duration_minutes)))
    returning * into att;
  end if;

  return jsonb_build_object(
    'attempt_id',att.id,'student_name',inv.student_name,'title',tst.title,
    'topic',tst.topic,'instructions',tst.instructions,'attempt_no',att.attempt_no,
    'started_at',att.started_at,'expires_at',att.expires_at,
    'questions',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',q.id,'type',q.type,'text',q.question_text,'options',q.options,'points',q.points
      ) order by picked.ordinality),'[]'::jsonb)
      from jsonb_array_elements_text(att.question_ids) with ordinality picked(question_id,ordinality)
      join public.test_questions q on q.id=picked.question_id::uuid
    )
  );
end $$;

create or replace function public.submit_test_attempt(p_token uuid,p_attempt_id uuid,p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.test_invitations;
  tst public.tests;
  att public.test_attempts;
  q record;
  earned numeric(10,2):=0;
  maximum numeric(10,2):=0;
  reveal boolean:=false;
  review jsonb:='[]'::jsonb;
  selected jsonb;
begin
  select * into inv from public.test_invitations where token=p_token;
  if inv.id is null then raise exception 'Ссылка недействительна'; end if;
  select * into att from public.test_attempts where id=p_attempt_id and invitation_id=inv.id for update;
  if att.id is null then raise exception 'Попытка не найдена'; end if;
  if att.status='submitted' then raise exception 'Тест уже отправлен'; end if;
  select * into tst from public.tests where id=att.test_id;

  if now()>att.expires_at or now()>tst.deadline_at then
    update public.test_attempts set status='expired',submitted_at=now(),score=0,max_score=0 where id=att.id;
    raise exception 'Время теста истекло';
  end if;

  for q in
    select tq.* from jsonb_array_elements_text(att.question_ids) with ordinality picked(question_id,ordinality)
    join public.test_questions tq on tq.id=picked.question_id::uuid
    order by picked.ordinality
  loop
    maximum:=maximum+q.points;
    selected:=coalesce(p_answers->q.id::text,'[]'::jsonb);
    earned:=earned+public.score_answer(q.type,q.scoring,selected,q.correct_answers,q.points);
  end loop;

  reveal:=tst.reveal_mode='after_submit' or (tst.reveal_mode='after_deadline' and now()>=tst.deadline_at);
  if reveal then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',tq.id,'text',tq.question_text,'selected',coalesce(p_answers->tq.id::text,'[]'::jsonb),
      'correct',tq.correct_answers,'explanation',tq.explanation,'points',tq.points,
      'earned',public.score_answer(tq.type,tq.scoring,coalesce(p_answers->tq.id::text,'[]'::jsonb),tq.correct_answers,tq.points)
    ) order by picked.ordinality),'[]'::jsonb) into review
    from jsonb_array_elements_text(att.question_ids) with ordinality picked(question_id,ordinality)
    join public.test_questions tq on tq.id=picked.question_id::uuid;
  end if;

  update public.test_attempts set answers=p_answers,score=earned,max_score=maximum,
    status='submitted',submitted_at=now() where id=att.id;

  return jsonb_build_object('score',earned,'max_score',maximum,
    'percent',case when maximum>0 then round(earned/maximum*100,1) else 0 end,
    'reveal',reveal,'review',review);
end $$;

create or replace function public.get_test_result(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.test_invitations;
  tst public.tests;
  att public.test_attempts;
  reveal boolean;
  review jsonb:='[]'::jsonb;
begin
  select * into inv from public.test_invitations where token=p_token;
  if inv.id is null then raise exception 'Ссылка недействительна'; end if;
  select * into att from public.test_attempts where invitation_id=inv.id and status='submitted'
    order by submitted_at desc limit 1;
  if att.id is null then return null; end if;
  select * into tst from public.tests where id=att.test_id;
  reveal:=tst.reveal_mode='after_submit' or (tst.reveal_mode='after_deadline' and now()>=tst.deadline_at);
  if reveal then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',tq.id,'text',tq.question_text,'selected',coalesce(att.answers->tq.id::text,'[]'::jsonb),
      'correct',tq.correct_answers,'explanation',tq.explanation,'points',tq.points,
      'earned',public.score_answer(tq.type,tq.scoring,coalesce(att.answers->tq.id::text,'[]'::jsonb),tq.correct_answers,tq.points)
    ) order by picked.ordinality),'[]'::jsonb) into review
    from jsonb_array_elements_text(att.question_ids) with ordinality picked(question_id,ordinality)
    join public.test_questions tq on tq.id=picked.question_id::uuid;
  end if;
  return jsonb_build_object('score',att.score,'max_score',att.max_score,
    'percent',case when att.max_score>0 then round(att.score/att.max_score*100,1) else 0 end,
    'submitted_at',att.submitted_at,'reveal',reveal,'review',review);
end $$;

revoke all on function public.test_invitation_info(uuid) from public;
revoke all on function public.start_test_attempt(uuid) from public;
revoke all on function public.submit_test_attempt(uuid,uuid,jsonb) from public;
revoke all on function public.get_test_result(uuid) from public;
grant execute on function public.test_invitation_info(uuid) to anon,authenticated;
grant execute on function public.start_test_attempt(uuid) to anon,authenticated;
grant execute on function public.submit_test_attempt(uuid,uuid,jsonb) to anon,authenticated;
grant execute on function public.get_test_result(uuid) to anon,authenticated;
