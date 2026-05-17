-- 0062: fix settlements.distribute to use the offering's total_shares as
-- the per-share divisor, not the sum of held shares.
--
-- Card 11 distributed by `sum(shares_held)`, which concentrated the entire
-- pool into the actual holders even though the IPO usually clears with
-- many shares unsold. Real-world semantic: each share represents one
-- unit of the player's buy-in (total_shares == declared buy-in in $). If
-- the player loses, every share loses proportionally - held or not.
-- Unsold shares' implicit slice of the pool stays with treasury.

create or replace function settlements.distribute(
  p_settlement_event_id uuid,
  p_admin_user_id       uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event settlements.events%rowtype;
  v_offering ipo.offerings%rowtype;
  v_divisor bigint;
  v_holder record;
  v_user_avail uuid;
  v_treasury uuid := '00000000-0000-0000-0000-000000000001';
  v_per_share_minor bigint;
  v_payout bigint;
  v_legs jsonb;
  v_idem text;
  v_txn_id uuid;
  v_holders_paid int := 0;
  v_total_paid bigint := 0;
begin
  select * into v_event from settlements.events where settlement_event_id = p_settlement_event_id for update;
  if v_event.settlement_event_id is null then
    raise exception 'settlement_event_not_found' using errcode = '23503';
  end if;
  if v_event.status = 'distributed' then
    return jsonb_build_object('status','already_distributed','settlement_event_id', p_settlement_event_id);
  end if;
  if v_event.status = 'cancelled' then
    raise exception 'settlement_cancelled' using errcode = '22023';
  end if;
  if v_event.status = 'distributing' then
    raise exception 'settlement_already_distributing' using errcode = '22023';
  end if;

  update settlements.events set status='distributing' where settlement_event_id = p_settlement_event_id;

  -- Divisor: when bound to a specific offering, use that offering's
  -- total_shares (the player's buy-in slice count). When the event spans
  -- multiple offerings for a player, sum the total_shares across them.
  if v_event.offering_id is not null then
    select * into v_offering from ipo.offerings where offering_id = v_event.offering_id;
    v_divisor := coalesce(v_offering.total_shares, 0);
  else
    select coalesce(sum(o.total_shares), 0) into v_divisor
      from ipo.offerings o
     where o.player_id = v_event.player_id
       and o.session_state in ('active','halted','settling','settled');
  end if;

  if v_divisor = 0 then
    update settlements.events
       set status='distributed', distributed_at=now()
     where settlement_event_id = p_settlement_event_id;
    return jsonb_build_object('settlement_event_id', p_settlement_event_id,
      'status','distributed','holders_paid', 0, 'total_paid_minor', 0,
      'note','no_shares_minted');
  end if;

  v_per_share_minor := v_event.total_pool_minor / v_divisor;

  for v_holder in
    select p.user_id, p.shares_held, p.offering_id
      from ipo.portfolio p
      join ipo.offerings o on o.offering_id = p.offering_id
     where o.player_id = v_event.player_id
       and p.shares_held > 0
       and (v_event.offering_id is null or p.offering_id = v_event.offering_id)
     order by p.user_id, p.offering_id
  loop
    v_payout := v_holder.shares_held * v_per_share_minor;
    if v_payout = 0 then continue; end if;

    select account_id into v_user_avail from ledger.accounts
     where user_id = v_holder.user_id and account_type = 'available';
    if v_user_avail is null then
      insert into ledger.accounts (user_id, account_type) values (v_holder.user_id, 'available')
      on conflict (user_id, account_type) do nothing returning account_id into v_user_avail;
      if v_user_avail is null then
        select account_id into v_user_avail from ledger.accounts
         where user_id = v_holder.user_id and account_type = 'available';
      end if;
    end if;

    v_idem := format('settlement:%s:%s:%s', p_settlement_event_id, v_holder.user_id, v_holder.offering_id);
    v_legs := jsonb_build_array(
      jsonb_build_object('account_id', v_treasury::text, 'delta_minor', -v_payout),
      jsonb_build_object('account_id', v_user_avail::text, 'delta_minor', v_payout)
    );

    v_txn_id := ledger.post_transaction(
      v_holder.user_id, 'settlement_payout', v_legs, v_idem, p_admin_user_id,
      jsonb_build_object(
        'settlement_event_id', p_settlement_event_id,
        'player_id', v_event.player_id,
        'offering_id', v_holder.offering_id,
        'shares_held', v_holder.shares_held,
        'per_share_minor', v_per_share_minor,
        'total_shares_divisor', v_divisor
      ),
      false
    );

    v_holders_paid := v_holders_paid + 1;
    v_total_paid := v_total_paid + v_payout;
  end loop;

  update settlements.events
     set status='distributed',
         distributed_at=now(),
         metadata = metadata || jsonb_build_object(
           'per_share_minor', v_per_share_minor,
           'total_shares_divisor', v_divisor,
           'total_paid_minor', v_total_paid,
           'residual_minor', v_event.total_pool_minor - v_total_paid
         )
   where settlement_event_id = p_settlement_event_id;

  return jsonb_build_object(
    'settlement_event_id', p_settlement_event_id,
    'status', 'distributed',
    'holders_paid', v_holders_paid,
    'total_paid_minor', v_total_paid,
    'residual_minor', v_event.total_pool_minor - v_total_paid,
    'per_share_minor', v_per_share_minor,
    'total_shares_divisor', v_divisor,
    'note', 'pool ÷ minted shares (held + unsold). Residual stays with treasury.'
  );
end;
$$;

notify pgrst, 'reload schema';
