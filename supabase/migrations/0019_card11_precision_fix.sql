-- Card 11 precision fix (sovereign directive 2026-05-15):
-- "we'll do fractional shares, so we'll go to the $.00 and the rest stays
-- with treasury".
--
-- Original distribute() used (total_pool / total_shares) first, then
-- multiplied by shares_held - which floors per-share THEN multiplies,
-- compounding the rounding loss. Fixed: multiply-first, divide-last so
-- each holder gets the maximum integer-minor-unit (cent) payout, with
-- residual still staying with treasury.

set search_path = public;

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
  v_total_shares bigint;
  v_holder record;
  v_user_avail uuid;
  v_treasury uuid := '00000000-0000-0000-0000-000000000001';
  v_payout bigint;
  v_legs jsonb;
  v_idem text;
  v_txn_id uuid;
  v_holders_paid int := 0;
  v_total_paid bigint := 0;
  v_summary jsonb;
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

  if v_event.offering_id is not null then
    select coalesce(sum(shares_held),0) into v_total_shares
      from ipo.portfolio p
      join ipo.offerings o on o.offering_id = p.offering_id
     where o.offering_id = v_event.offering_id and p.shares_held > 0;
  else
    select coalesce(sum(p.shares_held),0) into v_total_shares
      from ipo.portfolio p
      join ipo.offerings o on o.offering_id = p.offering_id
     where o.player_id = v_event.player_id and p.shares_held > 0;
  end if;

  if v_total_shares = 0 then
    update settlements.events
       set status='distributed', distributed_at=now()
     where settlement_event_id = p_settlement_event_id;
    return jsonb_build_object('settlement_event_id', p_settlement_event_id,
      'status','distributed','holders_paid', 0, 'total_paid_minor', 0,
      'note','no_shares_outstanding');
  end if;

  for v_holder in
    select p.user_id, p.shares_held, p.offering_id
      from ipo.portfolio p
      join ipo.offerings o on o.offering_id = p.offering_id
     where o.player_id = v_event.player_id
       and p.shares_held > 0
       and (v_event.offering_id is null or p.offering_id = v_event.offering_id)
     order by p.user_id, p.offering_id
  loop
    -- Multiply-first divide-last: keeps full precision through the
    -- multiplication, then floors at the end. Residual stays with treasury.
    v_payout := (v_holder.shares_held * v_event.total_pool_minor) / v_total_shares;
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
        'total_pool_minor', v_event.total_pool_minor,
        'total_shares', v_total_shares,
        'payout_minor', v_payout
      ),
      false
    );

    v_holders_paid := v_holders_paid + 1;
    v_total_paid := v_total_paid + v_payout;
  end loop;

  update settlements.events
     set status = 'distributed',
         distributed_at = now()
   where settlement_event_id = p_settlement_event_id;

  v_summary := jsonb_build_object(
    'settlement_event_id', p_settlement_event_id,
    'player_id', v_event.player_id,
    'status', 'distributed',
    'holders_paid', v_holders_paid,
    'total_pool_minor', v_event.total_pool_minor,
    'total_paid_minor', v_total_paid,
    'residual_minor', v_event.total_pool_minor - v_total_paid,
    'note', 'multiply-first-divide-last precision; residual stays with treasury'
  );

  perform audit.log_event(
    'settlements','settlement_distributed',
    format('Settlement %s distributed %s minor across %s holders (residual %s)',
      p_settlement_event_id, v_total_paid, v_holders_paid, v_event.total_pool_minor - v_total_paid),
    'info', p_admin_user_id, null,
    v_summary, null, null, null, null
  );

  return v_summary;
end;
$$;

revoke all on function settlements.distribute(uuid, uuid) from public;
grant execute on function settlements.distribute(uuid, uuid) to service_role;

notify pgrst, 'reload schema';
