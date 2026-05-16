-- 0050: avatar_url column on profiles + storage bucket + RLS policies.

alter table public.profiles
  add column if not exists avatar_url text;

-- Public bucket so the URL can be loaded with no auth. RLS on storage.objects
-- restricts WRITE to the owning user. Path convention: '<user_id>/<filename>'.
insert into storage.buckets (id, name, public)
  values ('avatars', 'avatars', true)
  on conflict (id) do update set public = excluded.public;

-- Reset policies so this migration is idempotent.
drop policy if exists "avatars_public_read" on storage.objects;
drop policy if exists "avatars_owner_write" on storage.objects;
drop policy if exists "avatars_owner_update" on storage.objects;
drop policy if exists "avatars_owner_delete" on storage.objects;

create policy "avatars_public_read"
on storage.objects for select
using ( bucket_id = 'avatars' );

create policy "avatars_owner_write"
on storage.objects for insert
with check (
  bucket_id = 'avatars'
  and auth.uid()::text = (storage.foldername(name))[1]
);

create policy "avatars_owner_update"
on storage.objects for update
using (
  bucket_id = 'avatars'
  and auth.uid()::text = (storage.foldername(name))[1]
);

create policy "avatars_owner_delete"
on storage.objects for delete
using (
  bucket_id = 'avatars'
  and auth.uid()::text = (storage.foldername(name))[1]
);

notify pgrst, 'reload schema';
