-- Кабинет преподавателя: задания, аудиоотработка и уведомления — Beta 48
-- Выполните целиком один раз в том же проекте Supabase.

create extension if not exists pgcrypto;

create table if not exists public.course_assignments (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  subject_id text default '',
  subject_name text default '',
  group_id text default '',
  group_name text default '',
  course_id text default '',
  course_name text default '',
  lesson_number integer,
  lesson_topic text default '',
  assignment_type text not null default 'other',
  title text not null,
  description text default '',
  rubric text default '',
  max_score numeric(8,2) not null default 100 check (max_score > 0),
  deadline_at timestamptz,
  journal_criterion_id text default '',
  status text not null default 'published' check (status in ('draft','published','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.assignment_invitations (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.course_assignments(id) on delete cascade,
  student_id text not null,
  student_name text not null,
  student_email text default '',
  token uuid not null unique default gen_random_uuid(),
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique(assignment_id,student_id)
);

create table if not exists public.assignment_submissions (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.course_assignments(id) on delete cascade,
  invitation_id uuid not null references public.assignment_invitations(id) on delete cascade,
  version_no integer not null,
  storage_path text not null,
  file_name text not null,
  file_type text default '',
  file_size bigint not null check (file_size between 1 and 15728640),
  student_comment text default '',
  submitted_at timestamptz not null default now(),
  late boolean not null default false,
  status text not null default 'submitted'
    check (status in ('submitted','under_review','revision_requested','graded')),
  teacher_comment text default '',
  score numeric(8,2),
  graded_at timestamptz,
  unique(invitation_id,version_no)
);

alter table public.assignment_submissions
  drop constraint if exists assignment_submissions_file_size_check;
alter table public.assignment_submissions
  add constraint assignment_submissions_file_size_check
  check (file_size between 1 and 26214400);

create table if not exists public.teacher_assignment_notifications (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  assignment_id uuid not null references public.course_assignments(id) on delete cascade,
  submission_id uuid references public.assignment_submissions(id) on delete cascade,
  student_id text not null default '',
  student_name text not null default '',
  assignment_title text not null default '',
  subject_name text default '',
  group_name text default '',
  message text default '',
  created_at timestamptz not null default now(),
  read_at timestamptz,
  unique(submission_id)
);

create index if not exists assignment_inv_assignment_idx on public.assignment_invitations(assignment_id);
create index if not exists assignment_sub_assignment_idx on public.assignment_submissions(assignment_id);
create index if not exists assignment_sub_invitation_idx on public.assignment_submissions(invitation_id,version_no desc);
create index if not exists teacher_assignment_notifications_owner_idx
  on public.teacher_assignment_notifications(owner_id,created_at desc);

alter table public.course_assignments enable row level security;
alter table public.assignment_invitations enable row level security;
alter table public.assignment_submissions enable row level security;
alter table public.teacher_assignment_notifications enable row level security;

grant select,insert,update,delete on public.course_assignments to authenticated;
grant select,insert,update,delete on public.assignment_invitations to authenticated;
grant select,update,delete on public.assignment_submissions to authenticated;
grant select,update,delete on public.teacher_assignment_notifications to authenticated;

drop policy if exists "Teacher manages own cloud assignments" on public.course_assignments;
create policy "Teacher manages own cloud assignments" on public.course_assignments
for all to authenticated using (owner_id=auth.uid()) with check (owner_id=auth.uid());

drop policy if exists "Teacher manages own assignment invitations" on public.assignment_invitations;
create policy "Teacher manages own assignment invitations" on public.assignment_invitations
for all to authenticated
using (exists(select 1 from public.course_assignments a where a.id=assignment_id and a.owner_id=auth.uid()))
with check (exists(select 1 from public.course_assignments a where a.id=assignment_id and a.owner_id=auth.uid()));

drop policy if exists "Teacher manages own submissions" on public.assignment_submissions;
create policy "Teacher manages own submissions" on public.assignment_submissions
for all to authenticated
using (exists(select 1 from public.course_assignments a where a.id=assignment_id and a.owner_id=auth.uid()))
with check (exists(select 1 from public.course_assignments a where a.id=assignment_id and a.owner_id=auth.uid()));

drop policy if exists "Teacher reads own assignment notifications" on public.teacher_assignment_notifications;
create policy "Teacher reads own assignment notifications" on public.teacher_assignment_notifications
for select to authenticated using (owner_id=auth.uid());

drop policy if exists "Teacher updates own assignment notifications" on public.teacher_assignment_notifications;
create policy "Teacher updates own assignment notifications" on public.teacher_assignment_notifications
for update to authenticated using (owner_id=auth.uid()) with check (owner_id=auth.uid());

drop policy if exists "Teacher deletes own assignment notifications" on public.teacher_assignment_notifications;
create policy "Teacher deletes own assignment notifications" on public.teacher_assignment_notifications
for delete to authenticated using (owner_id=auth.uid());

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values(
  'assignment-submissions','assignment-submissions',false,26214400,
  array[
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'audio/webm',
    'audio/ogg',
    'audio/mpeg',
    'audio/mp4',
    'audio/x-m4a',
    'audio/wav',
    'audio/x-wav'
  ]
)
on conflict(id) do update set
  public=false,
  file_size_limit=26214400,
  allowed_mime_types=excluded.allowed_mime_types;

create or replace function public.assignment_upload_allowed(p_token text)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.assignment_invitations i
    join public.course_assignments a on a.id=i.assignment_id
    where i.token::text=p_token and a.status='published'
      and (a.deadline_at is null or now() <= a.deadline_at + interval '30 days')
  );
$$;
grant execute on function public.assignment_upload_allowed(text) to anon,authenticated;

drop policy if exists "Students upload assignment versions by token" on storage.objects;
create policy "Students upload assignment versions by token"
on storage.objects for insert to anon
with check (
  bucket_id='assignment-submissions'
  and public.assignment_upload_allowed((storage.foldername(name))[1])
);

drop policy if exists "Teachers read own assignment files" on storage.objects;
create policy "Teachers read own assignment files"
on storage.objects for select to authenticated
using (
  bucket_id='assignment-submissions'
  and exists(
    select 1 from public.assignment_invitations i
    join public.course_assignments a on a.id=i.assignment_id
    where i.token::text=(storage.foldername(name))[1] and a.owner_id=auth.uid()
  )
);

drop policy if exists "Teachers delete own assignment files" on storage.objects;
create policy "Teachers delete own assignment files"
on storage.objects for delete to authenticated
using (
  bucket_id='assignment-submissions'
  and exists(
    select 1 from public.assignment_invitations i
    join public.course_assignments a on a.id=i.assignment_id
    where i.token::text=(storage.foldername(name))[1] and a.owner_id=auth.uid()
  )
);

create or replace function public.assignment_info(p_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare inv public.assignment_invitations; a public.course_assignments; latest public.assignment_submissions;
begin
  select * into inv from public.assignment_invitations where token=p_token;
  if inv.id is null then raise exception 'Персональная ссылка недействительна'; end if;
  select * into a from public.course_assignments where id=inv.assignment_id;
  select * into latest from public.assignment_submissions
    where invitation_id=inv.id order by version_no desc limit 1;
  return jsonb_build_object(
    'assignment_id',a.id,'student_name',inv.student_name,'title',a.title,
    'assignment_type',a.assignment_type,'description',a.description,'rubric',a.rubric,
    'subject_name',a.subject_name,'group_name',a.group_name,'course_name',a.course_name,
    'lesson_number',a.lesson_number,'lesson_topic',a.lesson_topic,
    'max_score',a.max_score,'deadline_at',a.deadline_at,'assignment_status',a.status,
    'submission',case when latest.id is null then null else jsonb_build_object(
      'version',latest.version_no,'file_name',latest.file_name,'submitted_at',latest.submitted_at,
      'late',latest.late,'status',latest.status,'teacher_comment',latest.teacher_comment,
      'score',latest.score
    ) end,
    'versions',(select coalesce(jsonb_agg(jsonb_build_object(
      'version',s.version_no,'file_name',s.file_name,'submitted_at',s.submitted_at,
      'late',s.late,'status',s.status,'teacher_comment',s.teacher_comment,'score',s.score
    ) order by s.version_no desc),'[]'::jsonb) from public.assignment_submissions s where s.invitation_id=inv.id)
  );
end $$;

create or replace function public.submit_assignment(
  p_token uuid,p_storage_path text,p_file_name text,p_file_type text,p_file_size bigint,p_comment text default ''
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare inv public.assignment_invitations; a public.course_assignments; v integer; sub public.assignment_submissions;
begin
  select * into inv from public.assignment_invitations where token=p_token;
  if inv.id is null then raise exception 'Персональная ссылка недействительна'; end if;
  select * into a from public.course_assignments where id=inv.assignment_id;
  if a.status<>'published' then raise exception 'Приём работы закрыт'; end if;
  if p_file_size<1 or p_file_size>26214400 then raise exception 'Допустимый размер файла — до 25 МБ'; end if;
  if a.assignment_type='audio_retake' then
    if lower(p_file_name) !~ '\.(webm|ogg|mp3|m4a|mp4|wav)$' then
      raise exception 'Для аудиопересказа разрешены WEBM, OGG, MP3, M4A, MP4 и WAV';
    end if;
  elsif lower(p_file_name) !~ '\.(pdf|doc|docx)$' then
    raise exception 'Разрешены только PDF, DOC и DOCX';
  end if;
  if split_part(p_storage_path,'/',1)<>p_token::text then raise exception 'Некорректный путь файла'; end if;
  if not exists(select 1 from storage.objects where bucket_id='assignment-submissions' and name=p_storage_path) then
    raise exception 'Загруженный файл не найден';
  end if;
  select coalesce(max(version_no),0)+1 into v from public.assignment_submissions where invitation_id=inv.id;
  insert into public.assignment_submissions(
    assignment_id,invitation_id,version_no,storage_path,file_name,file_type,file_size,
    student_comment,late,status
  ) values(
    a.id,inv.id,v,p_storage_path,left(p_file_name,240),left(coalesce(p_file_type,''),120),p_file_size,
    left(coalesce(p_comment,''),2000),a.deadline_at is not null and now()>a.deadline_at,'submitted'
  ) returning * into sub;
  insert into public.teacher_assignment_notifications(
    owner_id,assignment_id,submission_id,student_id,student_name,assignment_title,
    subject_name,group_name,message
  ) values(
    a.owner_id,a.id,sub.id,inv.student_id,inv.student_name,a.title,
    a.subject_name,a.group_name,
    'Студент загрузил версию '||sub.version_no||': '||sub.file_name
  ) on conflict(submission_id) do nothing;
  return jsonb_build_object('accepted',true,'version',sub.version_no,'submitted_at',sub.submitted_at,'late',sub.late);
end $$;

grant execute on function public.assignment_info(uuid) to anon,authenticated;
grant execute on function public.submit_assignment(uuid,text,text,text,bigint,text) to anon,authenticated;
