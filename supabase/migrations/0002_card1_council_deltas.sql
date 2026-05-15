-- Card 1 council cross-poll deltas (poll d07d7b23, 2026-05-14)
-- Folds council convergence into the profiles schema before push.

-- 1. Lock down age_verified + dob writes so users can't self-flip the bit.
-- Claude.ai's blocking flag: a malicious client could POST age_verified=true
-- directly to /rest/v1/profiles and bypass the age gate.

drop policy if exists "profiles_update_own" on public.profiles;

create policy "profiles_update_own_safe"
  on public.profiles for update
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and age_verified = (select age_verified from public.profiles p2 where p2.user_id = auth.uid())
    and dob is not distinct from (select dob from public.profiles p2 where p2.user_id = auth.uid())
  );

-- 2. SECURITY DEFINER RPC for the age-gate path (server-side computes age from dob).
-- Route handler calls this instead of upsert.

create or replace function public.submit_age_gate(p_dob date)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_age integer;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;
  if p_dob is null or p_dob > current_date then
    raise exception 'invalid_dob' using errcode = '22023';
  end if;
  v_age := extract(year from age(current_date, p_dob));
  if v_age < 18 then
    raise exception 'underage' using errcode = '22023';
  end if;
  update public.profiles
     set dob = p_dob,
         age_verified = true
   where user_id = v_user;
end;
$$;

revoke all on function public.submit_age_gate(date) from public;
grant execute on function public.submit_age_gate(date) to authenticated;

-- 3. DB-level invariant: age_verified=true → dob is not null and user is 18+.
-- Belt + suspenders: even if the RLS escape hatch above leaked, the row can't
-- exist in a bypass-the-gate state.

alter table public.profiles
  drop constraint if exists profiles_age_verified_requires_dob;
alter table public.profiles
  add constraint profiles_age_verified_requires_dob
  check (
    age_verified = false
    or (dob is not null and dob <= current_date - interval '18 years')
  ) not valid;
alter table public.profiles validate constraint profiles_age_verified_requires_dob;

-- 4. Lock handle_new_user search_path (Postgres SECURITY DEFINER footgun
-- per Claude.ai). Recreate with explicit set.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

-- 5. GC-readiness + sweepstakes-compliance columns added now (cheap pre-fill,
-- avoids a future ALTER on a hot table). Per Claude.ai + DeepSeek convergence.

alter table public.profiles
  add column if not exists kyc_status text not null default 'none'
    check (kyc_status in ('none', 'pending', 'verified', 'rejected'));

alter table public.profiles
  add column if not exists tos_accepted_at timestamptz;

alter table public.profiles
  add column if not exists privacy_accepted_at timestamptz;

create index if not exists profiles_kyc_status_idx on public.profiles(kyc_status);
