-- 0051: 'player-photos' Storage bucket for admin-uploaded player avatars.
-- Public read; writes go through admin API (service_role bypasses RLS) so
-- no per-user write policy is needed.

insert into storage.buckets (id, name, public)
  values ('player-photos', 'player-photos', true)
  on conflict (id) do update set public = excluded.public;

drop policy if exists "player_photos_public_read" on storage.objects;

create policy "player_photos_public_read"
on storage.objects for select
using ( bucket_id = 'player-photos' );

notify pgrst, 'reload schema';
