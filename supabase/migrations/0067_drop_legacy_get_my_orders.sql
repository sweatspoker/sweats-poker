-- 0067: drop the legacy 1-arg public.get_my_orders(boolean) overload.
-- Migration 0058 added a 2-arg variant (p_include_closed, p_offering_id),
-- but the 1-arg form from 0013 was never dropped. PostgREST can't choose
-- between them when only p_include_closed is passed, returning a
-- "could not choose the best candidate function" error and 0 rows.
-- The Markets > My Trades unified view passes only p_include_closed,
-- so it hit this exact path and missed every user order.

drop function if exists public.get_my_orders(boolean);

notify pgrst, 'reload schema';
