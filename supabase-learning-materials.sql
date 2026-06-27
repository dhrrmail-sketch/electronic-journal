-- Выполните этот файл один раз в том же проекте Supabase.
-- Beta 66: хранилище учебных материалов теперь ПРИВАТНОЕ.
-- Доступ к файлам выдаётся только по временным подписанным ссылкам,
-- которые формирует преподаватель из приложения. Прямой публичный доступ закрыт.

-- Сделать бакет приватным (создаёт, если ещё нет).
insert into storage.buckets (id, name, public, file_size_limit)
values ('learning-materials', 'learning-materials', false, 26214400)
on conflict (id) do update
set public = false, file_size_limit = 26214400;

-- Убрать прежнее публичное чтение (если оно было создано ранней версией).
drop policy if exists "Public reads learning materials" on storage.objects;

-- Преподаватель читает только свои файлы. Этого достаточно, чтобы
-- сформировать подписанную ссылку (signed URL) и открыть предпросмотр.
-- Студенты получают уже подписанную ссылку и не обращаются к бакету напрямую.
drop policy if exists "Teachers read own learning materials" on storage.objects;
create policy "Teachers read own learning materials"
on storage.objects for select
to authenticated
using (
  bucket_id = 'learning-materials'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Teachers upload own learning materials" on storage.objects;
create policy "Teachers upload own learning materials"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'learning-materials'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Teachers update own learning materials" on storage.objects;
create policy "Teachers update own learning materials"
on storage.objects for update
to authenticated
using (
  bucket_id = 'learning-materials'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'learning-materials'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Teachers delete own learning materials" on storage.objects;
create policy "Teachers delete own learning materials"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'learning-materials'
  and (storage.foldername(name))[1] = auth.uid()::text
);
