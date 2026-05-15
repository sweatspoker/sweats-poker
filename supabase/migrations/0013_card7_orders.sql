-- Card 7 — Order book / trade execution (limit orders, price-time priority,
-- admin-triggered matching tick).
--
-- Council R1: DeepSeek + Claude.ai. 6/8 sub-questions unanimous; Q1/Q4
-- (auto-match vs admin-tick) split resolved by Gemini judge PICK CLAUDEAI
-- (admin-triggered match_book) + adjacent: self-trading prevention at
-- place_order RPC + 1-minor-unit tick (implicit via integer column).
-- GPT R2 deferred (screen lock).
--
-- Architecture:
--   - New `orders` schema with `orders.orders` and `orders.trades`.
--   - Two new escrow account_types: `escrow_order_buy` (GC) and
--     `escrow_order_shares` (per-offering shares — uses `offering_id`
--     metadata field on the account for per-player tracking).
--   - New transaction_types: order_placed, order_cancelled, trade_executed.
--   - `orders.place_order(user, player, offering, side, shares, limit_price,...)`
--     SECURITY DEFINER RPC: pure insertion + escrow posting. No matching
--     side-effects (testable in isolation).
--   - `orders.match_book(player_id, admin_user)` SECURITY DEFINER RPC:
--     walks the book in price-time order, executes crosses, settles
--     atomically (ledger + both portfolios + both orders in one DB txn).
--     Returns a summary.
--   - `orders.cancel_order(order_id, user)` SECURITY DEFINER RPC: instant
--     escrow refund.
--   - Self-trading prevention: matching engine skips pairs with same user_id.
--   - audit.events.source='order_book' for all order lifecycle events.

set search_path = public;

create schema if not exists orders;

-- =============================================================================
-- 1. Extend ledger.accounts CHECK with two new escrow types.
-- =============================================================================

alter table ledger.accounts
  drop constraint if exists accounts_type_check;

alter table ledger.accounts
  add constraint accounts_type_check check (account_type in (
    'available',
    'platform_treasury',
    'platform_float',
    'escrow_ipo_bid',
    'escrow_order_buy',      -- Card 7: GC locked by an open BUY order
    'escrow_order_shares'    -- Card 7: shares locked by an open SELL order
  ));

-- =============================================================================
-- 2. Extend ledger.transactions CHECK with three new types.
-- =============================================================================

alter table ledger.transactions
  drop constraint if exists transactions_type_check;

alter table ledger.transactions
  add constraint transactions_type_check check (transaction_type in (
    'admin_grant',
    'signup_bonus',
    'purchase_settled',
    'purchase_refunded',
    'ipo_bid_placed',
    'ipo_bid_cleared',
    'ipo_bid_refunded',
    'order_placed',
    'order_cancelled',
    'trade_executed'
  ));

-- =============================================================================
-- 3. orders.orders table.
-- =============================================================================

create table if not exists orders.orders (
  order_id            uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  player_id           text not null references players.players(player_id) on update cascade on delete no action,
  offering_id         uuid references ipo.offerings(offering_id) on update cascade on delete restrict,
  side                text not null,                       -- 'buy' | 'sell'
  shares              bigint not null,                     -- original requested shares
  shares_remaining    bigint not null,                     -- remaining after partial fills
  limit_price_minor   bigint not null,                     -- GC minor units per share
  status              text not null default 'open',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  expires_at          timestamptz,
  cancelled_at        timestamptz,
  filled_at           timestamptz,
  metadata            jsonb not null default '{}'::jsonb,
  constraint orders_side_check check (side in ('buy','sell')),
  constraint orders_status_check check (status in ('open','partially_filled','filled','cancelled','expired')),
  constraint orders_shares_positive check (shares > 0),
  constraint orders_shares_remaining_nonneg check (shares_remaining >= 0),
  constraint orders_shares_remaining_lte_total check (shares_remaining <= shares),
  constraint orders_limit_price_positive check (limit_price_minor > 0)
);

create index if not exists orders_player_side_price_time_idx
  on orders.orders (player_id, side, limit_price_minor, created_at)
  where status in ('open','partially_filled');

create index if not exists orders_user_open_idx
  on orders.orders (user_id, created_at desc)
  where status in ('open','partially_filled');

comment on table orders.orders is
  'Card 7: limit orders for player shares. Price-time priority. Cancellable. Admin-triggered matching via orders.match_book.';

-- =============================================================================
-- 4. orders.trades table (trade history).
-- =============================================================================

create table if not exists orders.trades (
  trade_id           uuid primary key default gen_random_uuid(),
  buy_order_id       uuid not null references orders.orders(order_id) on delete restrict,
  sell_order_id      uuid not null references orders.orders(order_id) on delete restrict,
  player_id          text not null references players.players(player_id),
  offering_id        uuid references ipo.offerings(offering_id),
  matched_shares     bigint not null,
  matched_price_minor bigint not null,
  executed_at        timestamptz not null default now(),
  trade_transaction_id uuid,                                -- soft-FK to ledger.transactions
  constraint trades_matched_shares_positive check (matched_shares > 0),
  constraint trades_matched_price_positive check (matched_price_minor > 0)
);

create index if not exists trades_player_executed_idx on orders.trades (player_id, executed_at desc);
create index if not exists trades_buy_idx on orders.trades (buy_order_id);
create index if not exists trades_sell_idx on orders.trades (sell_order_id);

-- =============================================================================
-- 5. RLS + grants.
-- =============================================================================

alter table orders.orders enable row level security;
alter table orders.trades enable row level security;

revoke all on all tables in schema orders from public, anon, authenticated;
alter default privileges in schema orders revoke all on tables from public, anon, authenticated;
grant usage on schema orders to service_role;
grant select, insert, update, delete on orders.orders, orders.trades to service_role;

-- =============================================================================
-- 6. orders.place_order — pure insertion + escrow posting. No matching.
--    Self-trade prevention is in match_book (skipping pairs with same user).
--    Tradeable gate via players.is_tradeable.
-- =============================================================================

create or replace function orders.place_order(
  p_user_id          uuid,
  p_player_id        text,
  p_side             text,
  p_shares           bigint,
  p_limit_price_minor bigint,
  p_idempotency_key  text,
  p_offering_id      uuid default null,
  p_initiated_by     uuid default null,
  p_expires_at       timestamptz default null,
  p_metadata         jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order_id uuid;
  v_user_avail uuid;
  v_escrow_id uuid;
  v_escrow_type text;
  v_cost bigint;
  v_portfolio_held bigint;
  v_legs jsonb;
  v_meta jsonb;
  v_txn_id uuid;
begin
  if p_side not in ('buy','sell') then
    raise exception 'invalid_side' using errcode = '22023';
  end if;
  if p_shares is null or p_shares <= 0 then
    raise exception 'shares_must_be_positive' using errcode = '22023';
  end if;
  if p_limit_price_minor is null or p_limit_price_minor <= 0 then
    raise exception 'limit_price_must_be_positive' using errcode = '22023';
  end if;
  if not players.is_tradeable(p_player_id) then
    raise exception 'player_not_tradeable' using errcode = '22023',
      detail = format('player_id=%s', p_player_id);
  end if;

  v_cost := p_shares * p_limit_price_minor;
  v_escrow_type := case when p_side = 'buy' then 'escrow_order_buy' else 'escrow_order_shares' end;

  -- Insert the order first (status='open').
  insert into orders.orders (user_id, player_id, offering_id, side, shares, shares_remaining, limit_price_minor, status, expires_at, metadata)
  values (p_user_id, p_player_id, p_offering_id, p_side, p_shares, p_shares, p_limit_price_minor, 'open', p_expires_at, p_metadata)
  returning order_id into v_order_id;

  if p_side = 'buy' then
    -- Buy: escrow GC. Available → escrow_order_buy.
    select account_id into v_user_avail from ledger.accounts where user_id = p_user_id and account_type = 'available';
    if v_user_avail is null then
      raise exception 'user_available_not_found' using errcode = '23503';
    end if;
    select account_id into v_escrow_id from ledger.accounts where user_id = p_user_id and account_type = v_escrow_type;
    if v_escrow_id is null then
      insert into ledger.accounts (user_id, account_type) values (p_user_id, v_escrow_type)
      on conflict (user_id, account_type) do nothing returning account_id into v_escrow_id;
      if v_escrow_id is null then
        select account_id into v_escrow_id from ledger.accounts where user_id = p_user_id and account_type = v_escrow_type;
      end if;
    end if;
    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', -v_cost),
      jsonb_build_object('account_id', v_escrow_id::text, 'delta_minor', v_cost)
    );
  else
    -- Sell: debit portfolio shares (portfolio is authoritative). Also write
    -- a ledger row with synthetic legs against escrow_order_shares so the
    -- ledger audit can see the shares-side commitment without a portfolio join.
    select shares_held into v_portfolio_held from ipo.portfolio where user_id = p_user_id and offering_id = p_offering_id;
    if v_portfolio_held is null or v_portfolio_held < p_shares then
      raise exception 'insufficient_shares' using errcode = '23514',
        detail = format('held=%s requested=%s', coalesce(v_portfolio_held,0), p_shares);
    end if;

    -- Debit portfolio. (Locked shares can't be sold twice — sell-order
    -- placement reduces shares_held immediately. Refund on cancel/expire.)
    update ipo.portfolio
       set shares_held = shares_held - p_shares,
           last_updated_at = now()
     where user_id = p_user_id and offering_id = p_offering_id;

    -- Ledger-visible escrow: synthetic 0-GC entry that records the commitment.
    -- Use platform_treasury sentinel for the counter-leg so the txn balances
    -- (sum=0). The shares-as-account-balance is a synthetic representation
    -- since portfolio is authoritative; this is for audit visibility only.
    select account_id into v_escrow_id from ledger.accounts where user_id = p_user_id and account_type = v_escrow_type;
    if v_escrow_id is null then
      insert into ledger.accounts (user_id, account_type) values (p_user_id, v_escrow_type)
      on conflict (user_id, account_type) do nothing returning account_id into v_escrow_id;
      if v_escrow_id is null then
        select account_id into v_escrow_id from ledger.accounts where user_id = p_user_id and account_type = v_escrow_type;
      end if;
    end if;
    -- Use minor-units = shares count for audit visibility. Counter-leg against
    -- platform_treasury sentinel.
    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', v_escrow_id::text, 'delta_minor', p_shares),
      jsonb_build_object('account_id', '00000000-0000-0000-0000-000000000001', 'delta_minor', -p_shares)
    );
  end if;

  v_meta := p_metadata || jsonb_build_object(
    'order_id', v_order_id,
    'player_id', p_player_id,
    'offering_id', p_offering_id,
    'side', p_side,
    'shares', p_shares,
    'limit_price_minor', p_limit_price_minor
  );

  v_txn_id := ledger.post_transaction(
    p_user_id, 'order_placed', v_legs, p_idempotency_key,
    coalesce(p_initiated_by, p_user_id), v_meta, true
  );

  perform audit.log_event(
    'order_book', 'order_placed',
    format('User placed %s order for %s shares of %s @ %s', p_side, p_shares, p_player_id, p_limit_price_minor),
    'info', coalesce(p_initiated_by, p_user_id), p_user_id,
    jsonb_build_object('order_id', v_order_id, 'player_id', p_player_id, 'side', p_side, 'shares', p_shares, 'price', p_limit_price_minor),
    v_txn_id, p_idempotency_key, null, null
  );

  return v_order_id;
end;
$$;

revoke all on function orders.place_order(uuid, text, text, bigint, bigint, text, uuid, uuid, timestamptz, jsonb) from public;
grant execute on function orders.place_order(uuid, text, text, bigint, bigint, text, uuid, uuid, timestamptz, jsonb) to service_role;

-- =============================================================================
-- 7. orders.cancel_order — instant refund.
-- =============================================================================

create or replace function orders.cancel_order(
  p_order_id        uuid,
  p_user_id         uuid,
  p_idempotency_key text default null
) returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order orders.orders%rowtype;
  v_user_avail uuid;
  v_escrow_id uuid;
  v_escrow_type text;
  v_cost bigint;
  v_legs jsonb;
  v_idem text;
  v_txn_id uuid;
begin
  select * into v_order from orders.orders where order_id = p_order_id for update;
  if v_order.order_id is null then
    raise exception 'order_not_found' using errcode = '23503';
  end if;
  if v_order.user_id <> p_user_id then
    raise exception 'order_not_owned_by_user' using errcode = '42501';
  end if;
  if v_order.status not in ('open','partially_filled') then
    raise exception 'order_not_cancellable' using errcode = '22023',
      detail = format('status=%s', v_order.status);
  end if;

  v_cost := v_order.shares_remaining * v_order.limit_price_minor;
  v_escrow_type := case when v_order.side = 'buy' then 'escrow_order_buy' else 'escrow_order_shares' end;

  -- Refund: escrow → available (for buy) or shares → portfolio (for sell).
  if v_order.side = 'buy' then
    select account_id into v_user_avail from ledger.accounts where user_id = p_user_id and account_type = 'available';
    select account_id into v_escrow_id from ledger.accounts where user_id = p_user_id and account_type = v_escrow_type;
    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', v_escrow_id::text, 'delta_minor', -v_cost),
      jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', v_cost)
    );
  else
    -- Credit portfolio back.
    update ipo.portfolio
       set shares_held = shares_held + v_order.shares_remaining,
           last_updated_at = now()
     where user_id = p_user_id and offering_id = v_order.offering_id;

    select account_id into v_escrow_id from ledger.accounts where user_id = p_user_id and account_type = v_escrow_type;
    -- Counter-leg: shares come back from escrow to treasury sentinel (ledger-visible accounting).
    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', v_escrow_id::text, 'delta_minor', -v_order.shares_remaining),
      jsonb_build_object('account_id', '00000000-0000-0000-0000-000000000001', 'delta_minor', v_order.shares_remaining)
    );
  end if;

  v_idem := coalesce(p_idempotency_key, 'cancel:' || p_order_id::text);
  v_txn_id := ledger.post_transaction(
    p_user_id, 'order_cancelled', v_legs, v_idem,
    p_user_id, jsonb_build_object('order_id', p_order_id, 'cancelled_shares', v_order.shares_remaining), true
  );

  update orders.orders
     set status = 'cancelled',
         cancelled_at = now(),
         updated_at = now()
   where order_id = p_order_id;

  perform audit.log_event(
    'order_book', 'order_cancelled',
    format('Order %s cancelled (%s shares remaining refunded)', p_order_id, v_order.shares_remaining),
    'info', p_user_id, p_user_id,
    jsonb_build_object('order_id', p_order_id, 'remaining_at_cancel', v_order.shares_remaining),
    v_txn_id, v_idem, null, null
  );

  return true;
end;
$$;

revoke all on function orders.cancel_order(uuid, uuid, text) from public;
grant execute on function orders.cancel_order(uuid, uuid, text) to service_role;

-- =============================================================================
-- 8. orders.match_book — admin-triggered matching tick.
--    Price-time priority. Self-trading prevention. Atomic settlement.
-- =============================================================================

create or replace function orders.match_book(
  p_player_id     text,
  p_admin_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_buy orders.orders%rowtype;
  v_sell orders.orders%rowtype;
  v_match_shares bigint;
  v_match_price bigint;
  v_total_value bigint;
  v_trade_id uuid;
  v_trades int := 0;
  v_total_shares bigint := 0;
  v_summary jsonb;
  v_buy_avail uuid;
  v_buy_escrow uuid;
  v_sell_avail uuid;
  v_sell_escrow uuid;
  v_legs jsonb;
  v_txn_id uuid;
  v_idem text;
begin
  -- Loop: find the best opposite-side pair (highest BUY ≥ lowest SELL), skip
  -- self-matches, execute one trade per iteration. Exit when no cross exists.
  loop
    -- Best BUY: highest limit_price, then earliest created_at.
    select * into v_buy from orders.orders
     where player_id = p_player_id and side = 'buy' and status in ('open','partially_filled')
     order by limit_price_minor desc, created_at asc, order_id asc
     limit 1
     for update skip locked;

    if v_buy.order_id is null then exit; end if;

    -- Best SELL with price <= best buy, AND different user (self-trade prevention).
    select * into v_sell from orders.orders
     where player_id = p_player_id and side = 'sell' and status in ('open','partially_filled')
       and limit_price_minor <= v_buy.limit_price_minor
       and user_id <> v_buy.user_id
     order by limit_price_minor asc, created_at asc, order_id asc
     limit 1
     for update skip locked;

    if v_sell.order_id is null then exit; end if;

    v_match_shares := least(v_buy.shares_remaining, v_sell.shares_remaining);
    -- Price-time priority: trade executes at the resting (earlier) order's price.
    v_match_price := case when v_sell.created_at < v_buy.created_at then v_sell.limit_price_minor else v_buy.limit_price_minor end;
    v_total_value := v_match_shares * v_match_price;

    -- Resolve accounts.
    select account_id into v_buy_avail from ledger.accounts where user_id = v_buy.user_id and account_type = 'available';
    select account_id into v_buy_escrow from ledger.accounts where user_id = v_buy.user_id and account_type = 'escrow_order_buy';
    select account_id into v_sell_avail from ledger.accounts where user_id = v_sell.user_id and account_type = 'available';
    select account_id into v_sell_escrow from ledger.accounts where user_id = v_sell.user_id and account_type = 'escrow_order_shares';
    -- Lazy-create seller's available account if missing.
    if v_sell_avail is null then
      insert into ledger.accounts (user_id, account_type) values (v_sell.user_id, 'available')
      on conflict (user_id, account_type) do nothing returning account_id into v_sell_avail;
      if v_sell_avail is null then
        select account_id into v_sell_avail from ledger.accounts where user_id = v_sell.user_id and account_type = 'available';
      end if;
    end if;

    -- Ledger transaction (GC side):
    --   Buyer's escrow_order_buy → Seller's available     (= v_total_value)
    -- Note: buy escrow was charged at the limit price; if matched at a lower
    -- price (price improvement), refund the difference to buyer's available.
    declare
      v_refund_buyer bigint := v_match_shares * (v_buy.limit_price_minor - v_match_price);
    begin
      if v_refund_buyer > 0 then
        v_legs := jsonb_build_array(
          jsonb_build_object('account_id', v_buy_escrow::text, 'delta_minor', -(v_total_value + v_refund_buyer)),
          jsonb_build_object('account_id', v_sell_avail::text, 'delta_minor', v_total_value),
          jsonb_build_object('account_id', v_buy_avail::text, 'delta_minor', v_refund_buyer)
        );
      else
        v_legs := jsonb_build_array(
          jsonb_build_object('account_id', v_buy_escrow::text, 'delta_minor', -v_total_value),
          jsonb_build_object('account_id', v_sell_avail::text, 'delta_minor', v_total_value)
        );
      end if;
    end;

    v_idem := format('trade:%s:%s:%s', v_buy.order_id, v_sell.order_id, v_match_shares);
    v_txn_id := ledger.post_transaction(
      v_buy.user_id, 'trade_executed', v_legs, v_idem, p_admin_user_id,
      jsonb_build_object(
        'buy_order_id', v_buy.order_id,
        'sell_order_id', v_sell.order_id,
        'matched_shares', v_match_shares,
        'matched_price_minor', v_match_price,
        'player_id', p_player_id
      ),
      false  -- buyer must be age-verified to have placed bid; recheck not needed at settle
    );

    -- Portfolio writes (Card 5 atomic pattern): buyer gains, seller's locked already decremented at order_placed
    -- so we just credit the buyer's portfolio and decrement seller's escrow_order_shares ledger account.
    insert into ipo.portfolio (user_id, offering_id, shares_held, weighted_avg_cost_minor, first_acquired_at)
    values (v_buy.user_id, v_sell.offering_id, v_match_shares, v_match_price, now())
    on conflict (user_id, offering_id) do update
      set shares_held = ipo.portfolio.shares_held + excluded.shares_held,
          weighted_avg_cost_minor = (
            (ipo.portfolio.shares_held * ipo.portfolio.weighted_avg_cost_minor + excluded.shares_held * excluded.weighted_avg_cost_minor)
            / nullif(ipo.portfolio.shares_held + excluded.shares_held, 0)
          ),
          last_updated_at = now();

    -- Seller's escrow_order_shares debit: ledger-visible.
    perform ledger.post_transaction(
      v_sell.user_id, 'trade_executed',
      jsonb_build_array(
        jsonb_build_object('account_id', v_sell_escrow::text, 'delta_minor', -v_match_shares),
        jsonb_build_object('account_id', '00000000-0000-0000-0000-000000000001', 'delta_minor', v_match_shares)
      ),
      v_idem || ':sell-side',
      p_admin_user_id,
      jsonb_build_object('buy_order_id', v_buy.order_id, 'sell_order_id', v_sell.order_id, 'matched_shares', v_match_shares, 'side', 'sell-side-shares-burn'),
      false
    );

    -- Trade row.
    insert into orders.trades (buy_order_id, sell_order_id, player_id, offering_id, matched_shares, matched_price_minor, trade_transaction_id)
    values (v_buy.order_id, v_sell.order_id, p_player_id, v_sell.offering_id, v_match_shares, v_match_price, v_txn_id)
    returning trade_id into v_trade_id;

    -- Update both orders.
    update orders.orders
       set shares_remaining = shares_remaining - v_match_shares,
           status = case when shares_remaining - v_match_shares = 0 then 'filled' else 'partially_filled' end,
           filled_at = case when shares_remaining - v_match_shares = 0 then now() else filled_at end,
           updated_at = now()
     where order_id in (v_buy.order_id, v_sell.order_id);

    perform audit.log_event(
      'order_book', 'trade_executed',
      format('Trade %s shares @ %s on %s', v_match_shares, v_match_price, p_player_id),
      'info', p_admin_user_id, null,
      jsonb_build_object('trade_id', v_trade_id, 'buy_order_id', v_buy.order_id, 'sell_order_id', v_sell.order_id,
                         'matched_shares', v_match_shares, 'matched_price', v_match_price, 'player_id', p_player_id),
      v_txn_id, v_idem, null, null
    );

    v_trades := v_trades + 1;
    v_total_shares := v_total_shares + v_match_shares;
  end loop;

  v_summary := jsonb_build_object(
    'player_id', p_player_id,
    'trades_executed', v_trades,
    'total_shares_matched', v_total_shares,
    'matched_at', now()
  );

  if v_trades > 0 then
    perform audit.log_event(
      'order_book', 'match_book_tick',
      format('match_book(%s) executed %s trades, %s shares', p_player_id, v_trades, v_total_shares),
      'info', p_admin_user_id, null,
      v_summary, null, null, null, null
    );
  end if;

  return v_summary;
end;
$$;

revoke all on function orders.match_book(text, uuid) from public;
grant execute on function orders.match_book(text, uuid) to service_role;

-- =============================================================================
-- 9. PostgREST shims.
-- =============================================================================

create or replace function public.orders_place_order(
  p_user_id uuid, p_player_id text, p_side text, p_shares bigint,
  p_limit_price_minor bigint, p_idempotency_key text,
  p_offering_id uuid default null, p_initiated_by uuid default null,
  p_expires_at timestamptz default null, p_metadata jsonb default '{}'::jsonb
) returns uuid language sql security definer set search_path = public, pg_temp
as $$
  select orders.place_order(p_user_id, p_player_id, p_side, p_shares, p_limit_price_minor, p_idempotency_key, p_offering_id, p_initiated_by, p_expires_at, p_metadata);
$$;
revoke all on function public.orders_place_order(uuid, text, text, bigint, bigint, text, uuid, uuid, timestamptz, jsonb) from public;
grant execute on function public.orders_place_order(uuid, text, text, bigint, bigint, text, uuid, uuid, timestamptz, jsonb) to service_role;

create or replace function public.orders_match_book(p_player_id text, p_admin_user_id uuid)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select orders.match_book(p_player_id, p_admin_user_id); $$;
revoke all on function public.orders_match_book(text, uuid) from public;
grant execute on function public.orders_match_book(text, uuid) to service_role;

create or replace function public.orders_cancel_order(p_order_id uuid, p_user_id uuid, p_idempotency_key text default null)
returns boolean language sql security definer set search_path = public, pg_temp
as $$ select orders.cancel_order(p_order_id, p_user_id, p_idempotency_key); $$;
revoke all on function public.orders_cancel_order(uuid, uuid, text) from public;
grant execute on function public.orders_cancel_order(uuid, uuid, text) to service_role;

-- =============================================================================
-- 10. User-scoped read shims.
-- =============================================================================

create or replace function public.get_my_orders(p_include_closed boolean default false)
returns table (
  order_id uuid, player_id text, side text, shares bigint, shares_remaining bigint,
  limit_price_minor bigint, status text, created_at timestamptz, expires_at timestamptz
) language sql security definer set search_path = public, pg_temp
as $$
  select o.order_id, o.player_id, o.side, o.shares, o.shares_remaining,
         o.limit_price_minor, o.status, o.created_at, o.expires_at
    from orders.orders o
   where o.user_id = (select auth.uid())
     and (p_include_closed or o.status in ('open','partially_filled'))
   order by o.created_at desc
   limit 500;
$$;
revoke all on function public.get_my_orders(boolean) from public;
grant execute on function public.get_my_orders(boolean) to authenticated;

create or replace function public.get_recent_trades(p_player_id text, p_limit int default 50)
returns table (
  trade_id uuid, matched_shares bigint, matched_price_minor bigint, executed_at timestamptz
) language sql security definer set search_path = public, pg_temp
as $$
  select t.trade_id, t.matched_shares, t.matched_price_minor, t.executed_at
    from orders.trades t
   where t.player_id = p_player_id
   order by t.executed_at desc
   limit greatest(1, least(p_limit, 500));
$$;
revoke all on function public.get_recent_trades(text, int) from public;
grant execute on function public.get_recent_trades(text, int) to authenticated, anon;

notify pgrst, 'reload schema';
