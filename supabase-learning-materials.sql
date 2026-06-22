-- Выполните этот файл один раз в том же проекте Supabase.
-- Он создаёт публичное хранилище учебных материалов.

insert into storage.buckets (id, name, public, file_size_limit)
values ('learning-materials', 'learning-materials', true, 26214400)
on conflict (id) do update
set public = true, file_size_limit = 26214400;

drop policy if exists "Public reads learning materials" on storage.objects;
create policy "Public reads learning materials"
on storage.objects for select
to public
using (bucket_id = 'learning-materials');

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
