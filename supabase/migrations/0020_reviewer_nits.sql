-- Post-build reviewer-audit nits (Gemini reviewer 2026-05-15 on Cards 6-12):
--
-- Card 6 nit: players.upsert_player audit format string used p_display_name
-- twice in the "from → to" diff position, making the text diff useless. The
-- metadata payload captured the diff correctly, but the human-readable
-- message was misleading. Fixed: show actual status transition.
--
-- Card 7 nit: orders.match_book did not filter expired orders from the book.
-- Until an external cleanup job marked them 'expired', they remained
-- matchable. Fixed: skip orders where expires_at IS NOT NULL AND expires_at < now().

set search_path = public;

create or replace function players.upsert_player(
  p_player_id     text,
  p_display_name  text,
  p_sport         text,
  p_player_position text default null,
  p_league        text default null,
  p_photo_url     text default null,
  p_status        text default 'active',
  p_admin_user_id uuid default null,
  p_metadata      jsonb default '{}'::jsonb
) returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_was_new boolean := false;
  v_prev_status text;
begin
  if p_player_id is null or length(p_player_id) = 0 then
    raise exception 'player_id_required' using errcode = '22023';
  end if;

  select status into v_prev_status from players.players where player_id = p_player_id;
  if v_prev_status is null then
    v_was_new := true;
  end if;

  insert into players.players (player_id, display_name, sport, player_position, league, photo_url, status, metadata)
  values (p_player_id, p_display_name, p_sport, p_player_position, p_league, p_photo_url, p_status, p_metadata)
  on conflict (player_id) do update
    set display_name = excluded.display_name,
        sport = excluded.sport,
        player_position = excluded.player_position,
        league = excluded.league,
        photo_url = excluded.photo_url,
        status = excluded.status,
        metadata = excluded.metadata,
        updated_at = now();

  -- Card 6 audit format fix: distinct status transition string instead of
  -- "display_name: X → X". Falls back to "created" for new rows.
  perform audit.log_event(
    'players',
    case when v_was_new then 'player_created' else 'player_updated' end,
    case when v_was_new
      then format('Player %s created (%s, %s, status=%s)', p_player_id, p_display_name, p_sport, p_status)
      else format('Player %s updated (status: %s → %s)', p_player_id, coalesce(v_prev_status,'(missing)'), p_status)
    end,
    case when p_status = 'suspended' or p_status = 'retired' then 'warning' else 'info' end,
    p_admin_user_id, null,
    jsonb_build_object('player_id', p_player_id, 'status', p_status, 'previous_status', v_prev_status, 'was_new', v_was_new),
    null, null, null, null
  );

  return p_player_id;
end;
$$;
revoke all on function players.upsert_player(text, text, text, text, text, text, text, uuid, jsonb) from public;
grant execute on function players.upsert_player(text, text, text, text, text, text, text, uuid, jsonb) to service_role;

-- =============================================================================
-- Card 7 nit: match_book skips expired orders.
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
  loop
    -- Best BUY: skip expired.
    select * into v_buy from orders.orders
     where player_id = p_player_id and side = 'buy' and status in ('open','partially_filled')
       and (expires_at is null or expires_at > now())
     order by limit_price_minor desc, created_at asc, order_id asc
     limit 1
     for update skip locked;

    if v_buy.order_id is null then exit; end if;

    -- Best SELL with price <= best buy, different user, not expired.
    select * into v_sell from orders.orders
     where player_id = p_player_id and side = 'sell' and status in ('open','partially_filled')
       and limit_price_minor <= v_buy.limit_price_minor
       and user_id <> v_buy.user_id
       and (expires_at is null or expires_at > now())
     order by limit_price_minor asc, created_at asc, order_id asc
     limit 1
     for update skip locked;

    if v_sell.order_id is null then exit; end if;

    v_match_shares := least(v_buy.shares_remaining, v_sell.shares_remaining);
    v_match_price := case when v_sell.created_at < v_buy.created_at then v_sell.limit_price_minor else v_buy.limit_price_minor end;
    v_total_value := v_match_shares * v_match_price;

    select account_id into v_buy_avail from ledger.accounts where user_id = v_buy.user_id and account_type = 'available';
    select account_id into v_buy_escrow from ledger.accounts where user_id = v_buy.user_id and account_type = 'escrow_order_buy';
    select account_id into v_sell_avail from ledger.accounts where user_id = v_sell.user_id and account_type = 'available';
    select account_id into v_sell_escrow from ledger.accounts where user_id = v_sell.user_id and account_type = 'escrow_order_shares';
    if v_sell_avail is null then
      insert into ledger.accounts (user_id, account_type) values (v_sell.user_id, 'available')
      on conflict (user_id, account_type) do nothing returning account_id into v_sell_avail;
      if v_sell_avail is null then
        select account_id into v_sell_avail from ledger.accounts where user_id = v_sell.user_id and account_type = 'available';
      end if;
    end if;

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
      false
    );

    insert into ipo.portfolio (user_id, offering_id, shares_held, weighted_avg_cost_minor, first_acquired_at)
    values (v_buy.user_id, v_sell.offering_id, v_match_shares, v_match_price, now())
    on conflict (user_id, offering_id) do update
      set shares_held = ipo.portfolio.shares_held + excluded.shares_held,
          weighted_avg_cost_minor = (
            (ipo.portfolio.shares_held * ipo.portfolio.weighted_avg_cost_minor + excluded.shares_held * excluded.weighted_avg_cost_minor)
            / nullif(ipo.portfolio.shares_held + excluded.shares_held, 0)
          ),
          last_updated_at = now();

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

    insert into orders.trades (buy_order_id, sell_order_id, player_id, offering_id, matched_shares, matched_price_minor, trade_transaction_id)
    values (v_buy.order_id, v_sell.order_id, p_player_id, v_sell.offering_id, v_match_shares, v_match_price, v_txn_id)
    returning trade_id into v_trade_id;

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

notify pgrst, 'reload schema';
