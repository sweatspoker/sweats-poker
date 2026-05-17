-- 0075: rewrite platform.settings descriptions in plain English so the
-- admin Settings page stops leaking developer jargon ("minor units",
-- "escrow", "Sec 7", etc.). The setting_key names themselves stay
-- unchanged (they're DB identifiers used by callers), but the
-- operator-facing description text becomes self-explanatory and
-- consistent with the rest of the dashboard's "Type X to confirm"
-- voice.

update platform.settings set description = $$Default IPO clearing price when an admin creates a new offering. Stored as 1/100ths of a GC (so 100 = 1.00 GC). Per-share face value applied if no override is set.$$
  where setting_key = 'ipo_default_face_value_minor';

update platform.settings set description = $$How many minutes before the stream starts that bidding closes. After this point users can no longer place new IPO bids; the clearing engine runs.$$
  where setting_key = 'ipo_lead_close_minutes';

update platform.settings set description = $$How many minutes before the stream starts that IPO bidding opens. Users can place bids any time between this window and the close cutoff above.$$
  where setting_key = 'ipo_lead_open_minutes';

update platform.settings set description = $$Smallest allowed total bid amount per user (stored as 1/100ths of a GC, so 100 = 1.00 GC). 0 disables the floor entirely.$$
  where setting_key = 'ipo_minimum_bid_minor';

update platform.settings set description = $$How to handle trades that landed during a bad-data window after an operator error. "void" reverses them, "keep" leaves them as-is.$$
  where setting_key = 'operator_error_window_policy';

update platform.settings set description = $$Minutes before settlement when trading freezes. Open orders stay parked; new orders are blocked until the player cashes out and the settle is run.$$
  where setting_key = 'pre_settle_freeze_minutes';

update platform.settings set description = $$Minimum minutes a session has to run before voluntary cashout is allowed. Prevents instant-settle abuse.$$
  where setting_key = 'session_min_minutes';

update platform.settings set description = $$How much a user has to spend on their first top-up to auto-upgrade from "free" → "upgraded" tier. Stored as 1/100ths of a GC ($10 = 100 GC = 10000).$$
  where setting_key = 'tier_upgrade_threshold_minor';

update platform.settings set description = $$One-time GC bonus credited the moment a new user verifies their age. Stored as 1/100ths of a GC (1000 = 10 GC).$$
  where setting_key = 'welcome_bonus_minor';
