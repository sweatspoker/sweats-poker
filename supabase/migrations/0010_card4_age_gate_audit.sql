-- Card 4 — Gemini reviewer nit (STAMP-WITH-NITS):
-- submit_age_gate is the primary identity gate but currently only leaves an
-- audit trail via the resulting signup_bonus transaction. Add an explicit
-- audit.events row for the age_verified state change itself, so
-- compliance audit queries don't have to derive identity gating from
-- ledger side-effects.

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
    -- Card 4: log the underage rejection. The age_verified flag was not set,
    -- and post_transaction will not run, so this is the ONLY place an audit
    -- row is written for an attempted-but-rejected identity verification.
    perform audit.log_event(
      'age_gate', 'underage_rejected',
      'submit_age_gate rejected: claimed DOB makes user underage',
      'warning', v_user, v_user,
      jsonb_build_object('age_computed', v_age),
      null, null, null, null
    );
    raise exception 'underage' using errcode = '22023';
  end if;
  update public.profiles
     set dob = p_dob,
         age_verified = true
   where user_id = v_user;

  -- Card 4: explicit identity-gate audit. Independent of signup_bonus
  -- transaction so it's queryable directly: "show all age_verified state
  -- transitions for compliance audit", regardless of whether the bonus
  -- post succeeded.
  perform audit.log_event(
    'age_gate', 'age_verified',
    'User age-verified via submit_age_gate',
    'info', v_user, v_user,
    jsonb_build_object('age_computed', v_age),
    null, null, null, null
  );

  perform ledger.apply_signup_bonus(v_user);
end;
$$;

revoke all on function public.submit_age_gate(date) from public;
grant execute on function public.submit_age_gate(date) to authenticated;

notify pgrst, 'reload schema';
