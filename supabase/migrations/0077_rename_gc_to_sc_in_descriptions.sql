-- 0077: Rebrand from Gold Coins (GC) → Sweats Coins (SC) in all
-- operator-facing description text. Setting keys and minor-unit storage
-- stay unchanged (callers and balances are unaffected); only display
-- copy follows the rebrand.

update platform.settings set description = $$Default IPO clearing price when an admin creates a new offering. Stored as 1/100ths of a SC (so 100 = 1.00 SC). Per-share face value applied if no override is set.$$
  where setting_key = 'ipo_default_face_value_minor';

update platform.settings set description = $$Smallest allowed total bid amount per user (stored as 1/100ths of a SC, so 100 = 1.00 SC). 0 disables the floor entirely.$$
  where setting_key = 'ipo_minimum_bid_minor';

update platform.settings set description = $$How much a user has to spend on their first top-up to auto-upgrade from "free" → "upgraded" tier. Stored as 1/100ths of a SC ($10 = 100 SC = 10000).$$
  where setting_key = 'tier_upgrade_threshold_minor';

update platform.settings set description = $$One-time Sweats Coin bonus credited the moment a new user verifies their age. Stored as 1/100ths of a SC (1000 = 10 SC).$$
  where setting_key = 'welcome_bonus_minor';
