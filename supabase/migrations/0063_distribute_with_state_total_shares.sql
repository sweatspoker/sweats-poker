-- 0063: settlements.distribute_with_state was computing
-- final_share_value_minor as total_pool / sum(shares_held), same bug as
-- 0062 fixed in distribute(). Use offering.total_shares so the offering
-- column matches what every holder actually got per share.

create or replace function settlements.distribute_with_state(
  p_settlement_event_id uuid,
  p_admin_user_id       uuid
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_offering_id uuid;
  v_state text;
  v_result jsonb;
  v_total_shares bigint;
  v_total_pool bigint;
begin
  select offering_id into v_offering_id from settlements.events where settlement_event_id = p_settlement_event_id;

  if v_offering_id is not null then
    select session_state into v_state from ipo.offerings where offering_id = v_offering_id for update;
    if v_state = 'active' or v_state = 'halted' then
      perform ipo.transition_session(v_offering_id, 'settling', p_admin_user_id, 'settlement_distribute');
    elsif v_state not in ('settling','settled') then
      raise exception 'session_not_ready_for_settlement:%', v_state using errcode = '22023';
    end if;
  end if;

  v_result := settlements.distribute(p_settlement_event_id, p_admin_user_id);

  if v_offering_id is not null then
    select session_state into v_state from ipo.offerings where offering_id = v_offering_id for update;
    if v_state = 'settling' then
      select total_pool_minor into v_total_pool from settlements.events where settlement_event_id = p_settlement_event_id;
      -- Divisor is the offering's total_shares (player's buy-in slice count),
      -- not the sum of currently-held shares. Matches settlements.distribute.
      select coalesce(total_shares, 0) into v_total_shares from ipo.offerings where offering_id = v_offering_id;
      update ipo.offerings
         set final_chip_stack_minor   = v_total_pool,
             final_share_value_minor  = case when v_total_shares > 0 then v_total_pool / v_total_shares else 0 end
       where offering_id = v_offering_id;
      perform ipo.transition_session(v_offering_id, 'settled', p_admin_user_id, 'settlement_complete');
    end if;
  end if;

  return v_result;
end;
$$;

notify pgrst, 'reload schema';
