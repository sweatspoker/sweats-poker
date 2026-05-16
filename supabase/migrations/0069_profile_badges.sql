-- 0069: badge selection on profiles.
--
-- Tiers (lifetime_pnl_minor over settled positions):
--   shark   ≥ +100,000,000 minor (1mil+ GC)
--   crusher ≥  +10,000,000        (100k+)
--   grinder ≥   +1,000,000        (10k+)
--   nit     ≥           0
--   fish    <           0
--   donkey  ≤  -1,000,000        (10k-)
--   whale   ≤ -10,000,000        (100k-)
--   maniac  ≤ -100,000,000        (1mil-)
--
-- Unlocked tiers are computed client-side from get_my_results.performance.
-- This migration only persists the user's choice.

alter table public.profiles
  add column if not exists selected_badge text
    check (selected_badge in
      ('shark','crusher','grinder','nit','fish','donkey','whale','maniac')),
  add column if not exists show_badge_on_avatar boolean not null default true;

notify pgrst, 'reload schema';
