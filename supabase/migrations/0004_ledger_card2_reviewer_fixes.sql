-- Card 2 reviewer-pass fixes (Gemini reviewer verdict SHIP-WITH-FIXES, 2026-05-15)
-- Single HIGH finding: ledger.apply_signup_bonus was granted to `authenticated`
-- unnecessarily - submit_age_gate is SECURITY DEFINER so it can invoke owner-level
-- functions regardless of the caller's grants. Revoke to shrink the PostgREST attack
-- surface (no direct authenticated-callable path; only via submit_age_gate's chain).

revoke execute on function ledger.apply_signup_bonus(uuid) from authenticated;
