-- 0083: edit an offering's IPO window (opens_at / closes_at) and shares offered
--       (total_shares) before the auction clears.
--
-- Operators need to (a) change when an IPO closes and (b) change how many
-- shares are offered, after a player is on the roster but before clearing.
--
-- Guards:
--   * Only editable while the offering is pre-clear: session_state in
--     ('draft','ipo_open'). Once it is clearing/active/settling/settled/
--     halted/cancelled, the window + supply are locked.
--   * closes_at must be after opens_at.
--   * total_shares must be > 0, and may only change while the offering has
--     NO bids - changing supply after bids are in would corrupt the sealed-bid
--     clearing math. Window (opens/closes) edits are allowed with bids present
--     (e.g. extending the deadline). shares_remaining is kept equal to
--     total_shares (safe: no bids have consumed any when a shares edit is
--     permitted).

create or replace function streams.edit_offering(
  p_offering_id   uuid,
  p_opens_at      timestamptz default null,
  p_closes_at     timestamptz default null,
  p_total_shares  bigint      default null,
  p_admin_user_id uuid        default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_off       ipo.offerings%rowtype;
  v_opens     timestamptz;
  v_closes    timestamptz;
  v_bid_count int;
begin
  if p_admin_user_id is null then raise exception 'admin_user_id_required' using errcode = '22023'; end if;

  select * into v_off from ipo.offerings where offering_id = p_offering_id for update;
  if v_off.offering_id is null then raise exception 'offering_not_found:%', p_offering_id using errcode = '23503'; end if;

  if v_off.session_state not in ('draft','ipo_open') then
    raise exception 'offering_not_editable:% (only draft or ipo_open offerings can be edited)', v_off.session_state
      using errcode = '22023';
  end if;

  v_opens  := coalesce(p_opens_at,  v_off.opens_at);
  v_closes := coalesce(p_closes_at, v_off.closes_at);
  if v_closes <= v_opens then
    raise exception 'closes_at_must_be_after_opens_at' using errcode = '22023';
  end if;

  if p_total_shares is not null and p_total_shares <> v_off.total_shares then
    if p_total_shares <= 0 then
      raise exception 'total_shares_must_be_positive' using errcode = '22023';
    end if;
    select count(*) into v_bid_count from ipo.bids where offering_id = p_offering_id;
    if v_bid_count > 0 then
      raise exception 'cannot_change_shares_with_bids:% (cancel/refund bids first)', v_bid_count using errcode = '22023';
    end if;
  end if;

  update ipo.offerings
     set opens_at        = v_opens,
         closes_at       = v_closes,
         total_shares    = coalesce(p_total_shares, total_shares),
         shares_remaining = case when p_total_shares is not null then p_total_shares else shares_remaining end
   where offering_id = p_offering_id;

  perform audit.log_event(
    p_source        => 'streams',
    p_action_type   => 'offering_edited',
    p_message       => format('Offering %s (player %s) IPO edited: opens %s, closes %s, shares %s',
                              p_offering_id, v_off.player_id, v_opens, v_closes,
                              coalesce(p_total_shares, v_off.total_shares)),
    p_severity      => 'info',
    p_actor_user_id => p_admin_user_id,
    p_metadata      => jsonb_build_object(
      'offering_id', p_offering_id,
      'stream_id', v_off.stream_id,
      'player_id', v_off.player_id,
      'opens_at', v_opens,
      'closes_at', v_closes,
      'old_total_shares', v_off.total_shares,
      'new_total_shares', coalesce(p_total_shares, v_off.total_shares)
    )
  );
end;
$$;

create or replace function public.streams_edit_offering(
  p_offering_id   uuid,
  p_opens_at      timestamptz default null,
  p_closes_at     timestamptz default null,
  p_total_shares  bigint      default null,
  p_admin_user_id uuid        default null
) returns void language sql security definer set search_path = public, pg_temp as $$
  select streams.edit_offering(p_offering_id, p_opens_at, p_closes_at, p_total_shares, p_admin_user_id);
$$;

revoke all on function public.streams_edit_offering(uuid, timestamptz, timestamptz, bigint, uuid) from public;
grant execute on function public.streams_edit_offering(uuid, timestamptz, timestamptz, bigint, uuid) to service_role;

notify pgrst, 'reload schema';
