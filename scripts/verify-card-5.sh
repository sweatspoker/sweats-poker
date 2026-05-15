#!/usr/bin/env bash
# Card 5 (sealed-bid uniform-clearing-price auction) end-to-end verification.

set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .env.local ]]; then echo "ERROR: .env.local not found" >&2; exit 2; fi
DSN=$(grep '^SUPABASE_DB_URL=' .env.local | head -1 | cut -d= -f2-)
if [[ -z "$DSN" ]]; then echo "ERROR: SUPABASE_DB_URL not set" >&2; exit 2; fi
export SWEATS_DSN="$DSN"

python3 - <<'PY'
import os, sys, uuid, json, psycopg2
dsn = os.environ['SWEATS_DSN']
conn = psycopg2.connect(dsn); conn.autocommit = True
cur = conn.cursor()
PASS, FAIL = [], []
def aeq(n, g, w):
    if g == w: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n, g, w)); print(f"  FAIL {n}: got={g!r} want={w!r}")
def atrue(n, c, d=""):
    if c: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n, c, True)); print(f"  FAIL {n}: {d}")

print("=== Card 5 (auction) verification ===")

# --- 1. Schema ---
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='ipo' AND table_name='bids'")
aeq("schema.ipo_bids_table", cur.fetchone()[0], 1)
cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='accounts' AND c.conname='accounts_type_check'")
atrue("schema.platform_revenue_in_check", 'platform_revenue' in cur.fetchone()[0])
cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='transactions' AND c.conname='transactions_type_check'")
chk = cur.fetchone()[0]
for t in ('ipo_bid_placed','ipo_bid_raised','ipo_bid_cancelled','ipo_bid_cleared','ipo_bid_refunded'):
    atrue(f"schema.{t}_in_check", t in chk)

# --- 2. RPC presence ---
for fn in ('place_bid','raise_bid','cancel_bid','clear_offering'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ipo' AND p.proname=%s AND p.prosecdef", (fn,))
    aeq(f"rpc.ipo_{fn}_secdef", cur.fetchone()[0], 1)
for fn in ('ipo_place_bid','ipo_raise_bid','ipo_cancel_bid','ipo_clear_offering'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s", (fn,))
    aeq(f"rpc.public_{fn}_exists", cur.fetchone()[0], 1)

# --- 3. End-to-end auction smoke ---
# Seed test player + 3 synthetic bidders.
cur.execute("""INSERT INTO players.players (player_id, display_name, sport, status)
 VALUES ('p_c5_auction','Card 5 Auction Test','poker','active')
 ON CONFLICT (player_id) DO UPDATE SET status='active'""")
cur.execute("SELECT players.record_consent('p_c5_auction', 'v1.0', 'operator_attestation', NULL, NULL, NULL)")

bidders = [str(uuid.uuid4()) for _ in range(3)]
treasury_uid = '00000000-0000-0000-0000-000000000000'

for u in bidders:
    cur.execute("INSERT INTO auth.users (id) VALUES (%s) ON CONFLICT (id) DO NOTHING", (u,))
    cur.execute("UPDATE public.profiles SET display_name='C5 Test', age_verified=true, dob='1990-01-01', tier='upgraded' WHERE user_id=%s", (u,))
    cur.execute("INSERT INTO ledger.accounts (user_id, account_type) VALUES (%s, 'available') ON CONFLICT (user_id, account_type) DO NOTHING", (u,))
    cur.execute("SELECT ledger.admin_grant(%s, 100000, %s, %s, 'card-5 auction smoke')", (u, f"c5_grant_{u}", u))

# Create offering: 10 shares total, face value = 100 minor (1 GC face).
cur.execute("""INSERT INTO ipo.offerings (player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, opens_at, closes_at)
 VALUES ('p_c5_auction','Card 5 Auction Test', 10, 10, 100, now() - interval '1 minute', now() + interval '1 hour')
 RETURNING offering_id""")
oid = cur.fetchone()[0]
atrue("auction.offering_created", oid is not None)

# Place 3 bids at different prices:
#   bidder[0]: 5 shares @ 300 minor/share  → escrow 1500  (TOP BID)
#   bidder[1]: 4 shares @ 200 minor/share  → escrow 800   (MID BID)
#   bidder[2]: 6 shares @ 150 minor/share  → escrow 900   (LOW BID, will partially fill at 150)
# Total demand = 15 shares, supply = 10. Top + mid = 9 shares; low fills boundary 1 share.
# Clearing price = lowest accepted bid = 150 (the boundary). All winners pay 150/share.
# Premium = (150 - 100) * 10 = 500 → platform_revenue.
# Face = 100 * 10 = 1000 → platform_treasury.
# Overbid refunds: bidder[0] (300-150)*5=750; bidder[1] (200-150)*4=200; bidder[2] (150-150)*1=0.
# Unfilled refund: bidder[2] (6-1)*150=750.

bid_ids = []
prices = [300, 200, 150]
shares = [5, 4, 6]
for i in range(3):
    cur.execute("SELECT ipo.place_bid(%s, %s, %s, %s, %s, NULL)", (bidders[i], oid, shares[i], prices[i], f"c5_place_{i}_{uuid.uuid4()}"))
    bid_ids.append(cur.fetchone()[0])
aeq("auction.three_bids_placed", len(bid_ids), 3)

# Check escrow balances pre-clear.
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='escrow_ipo_bid'", (bidders[0],))
aeq("auction.bidder0_escrow", cur.fetchone()[0], 1500)
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='escrow_ipo_bid'", (bidders[1],))
aeq("auction.bidder1_escrow", cur.fetchone()[0], 800)
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='escrow_ipo_bid'", (bidders[2],))
aeq("auction.bidder2_escrow", cur.fetchone()[0], 900)

# --- 4. raise_bid: bidder[1] raises from 200 to 250.
cur.execute("SELECT ipo.raise_bid(%s, 250, %s, NULL)", (bid_ids[1], f"c5_raise_{uuid.uuid4()}"))
cur.execute("SELECT bid_price_per_share_minor, escrowed_minor, status FROM ipo.bids WHERE bid_id=%s", (bid_ids[1],))
price, escrow, status = cur.fetchone()
aeq("raise.new_price", price, 250)
aeq("raise.new_escrow", escrow, 1000)  # 4 * 250
aeq("raise.status_raised", status, 'raised')

# --- 5. Lowering rejected.
rejected = False
try:
    cur.execute("SELECT ipo.raise_bid(%s, 240, %s, NULL)", (bid_ids[1], f"c5_lower_{uuid.uuid4()}"))
except psycopg2.Error as e:
    if 'new_price_must_exceed_current' in str(e): rejected = True
atrue("raise.lower_rejected", rejected)

# --- 6. cancel_bid: place a 4th bid then cancel it; refund full.
extra_bidder = str(uuid.uuid4())
cur.execute("INSERT INTO auth.users (id) VALUES (%s) ON CONFLICT (id) DO NOTHING", (extra_bidder,))
cur.execute("UPDATE public.profiles SET display_name='C5 Cancel', age_verified=true, dob='1990-01-01', tier='upgraded' WHERE user_id=%s", (extra_bidder,))
cur.execute("INSERT INTO ledger.accounts (user_id, account_type) VALUES (%s, 'available') ON CONFLICT (user_id, account_type) DO NOTHING", (extra_bidder,))
cur.execute("SELECT ledger.admin_grant(%s, 10000, %s, %s, 'card-5 cancel smoke')", (extra_bidder, f"c5_extragrant_{extra_bidder}", extra_bidder))

# Snapshot AFTER all admin_grants so treasury delta only reflects auction flows.
cur.execute("SELECT account_type, balance_cached FROM ledger.accounts WHERE user_id=%s::uuid", (treasury_uid,))
sys_snap = dict(cur.fetchall())
cur.execute("SELECT ipo.place_bid(%s, %s, 1, 120, %s, NULL)", (extra_bidder, oid, f"c5_extra_{uuid.uuid4()}"))
extra_bid = cur.fetchone()[0]
cur.execute("SELECT ipo.cancel_bid(%s, %s, NULL)", (extra_bid, f"c5_cancel_{uuid.uuid4()}"))
cur.execute("SELECT status, escrowed_minor FROM ipo.bids WHERE bid_id=%s", (extra_bid,))
s, e = cur.fetchone()
aeq("cancel.status_cancelled", s, 'cancelled')
aeq("cancel.escrow_zero", e, 0)
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (extra_bidder,))
aeq("cancel.refund_to_available", cur.fetchone()[0], 11000)  # 10000 grant + 1000 welcome bonus

# --- 7. Clear the offering. Re-compute expectations with bidder[1] raised to 250:
#   Sorted: bidder[0]@300 (5 shares), bidder[1]@250 (4 shares), bidder[2]@150 (6 shares)
#   Fill: 5+4=9 shares; remaining 1 fills bidder[2]@150 (1 of 6).
#   Clearing price = 150 (bidder[2]'s price, the marginal bid).
#   Premium = (150-100)*10 = 500 to platform_revenue.
#   Face = 100*10 = 1000 to treasury.
#   bidder[0] overbid refund = (300-150)*5 = 750
#   bidder[1] overbid refund = (250-150)*4 = 400
#   bidder[2] overbid refund = (150-150)*1 = 0; unfilled refund = 5*150 = 750.
cur.execute("SELECT ipo.clear_offering(%s, NULL)", (oid,))
summary = cur.fetchone()[0]
aeq("clear.mechanic", summary['mechanic'], 'sealed_bid_uniform_clearing_price')
aeq("clear.total_filled", summary['total_filled'], 10)
aeq("clear.clearing_price", summary['clearing_price_per_share_minor'], 150)
aeq("clear.face_to_treasury", summary['total_face_to_treasury_minor'], 1000)
aeq("clear.premium_to_platform", summary['total_premium_to_platform_minor'], 500)
aeq("clear.winning_bidders", summary['winning_bidders'], 3)

# Portfolio allocations.
cur.execute("SELECT shares_held FROM ipo.portfolio WHERE user_id=%s AND offering_id=%s", (bidders[0], oid))
aeq("portfolio.bidder0_shares", cur.fetchone()[0], 5)
cur.execute("SELECT shares_held FROM ipo.portfolio WHERE user_id=%s AND offering_id=%s", (bidders[1], oid))
aeq("portfolio.bidder1_shares", cur.fetchone()[0], 4)
cur.execute("SELECT shares_held FROM ipo.portfolio WHERE user_id=%s AND offering_id=%s", (bidders[2], oid))
aeq("portfolio.bidder2_shares", cur.fetchone()[0], 1)

# Refund availability.
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (bidders[0],))
# initial 100000 grant + 1000 welcome - escrow 1500 + overbid refund 750 = 100250
aeq("post_clear.bidder0_available", cur.fetchone()[0], 100250)
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (bidders[1],))
# initial 100000 + 1000 welcome - escrow 1000 (after raise) + overbid 400 = 100400
aeq("post_clear.bidder1_available", cur.fetchone()[0], 100400)
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (bidders[2],))
# initial 100000 + 1000 welcome - escrow 900 + unfilled refund 750 + overbid 0 = 100850
aeq("post_clear.bidder2_available", cur.fetchone()[0], 100850)

# Treasury net +1000, platform_revenue net +500.
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='platform_treasury'", (treasury_uid,))
aeq("post_clear.treasury_delta", cur.fetchone()[0] - sys_snap.get('platform_treasury', 0), 1000)
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='platform_revenue'", (treasury_uid,))
aeq("post_clear.platform_revenue_delta", cur.fetchone()[0] - sys_snap.get('platform_revenue', 0), 500)

# Session state flipped to active via Card 13 trigger.
cur.execute("SELECT session_state FROM ipo.offerings WHERE offering_id=%s", (oid,))
aeq("post_clear.session_state_active", cur.fetchone()[0], 'active')

# Idempotency: re-clearing returns already_closed.
cur.execute("SELECT ipo.clear_offering(%s, NULL)", (oid,))
aeq("clear.idempotent", cur.fetchone()[0]['status'], 'already_closed')

# Drift check.
cur.execute("SELECT bool_and(ledger.verify_balance(account_id)) FROM ledger.accounts")
atrue("ledger.no_drift", cur.fetchone()[0])

# --- Cleanup (children before parents). Defensive: clean ALL offerings for
# this test player in case prior verify runs left orphans.
cur.execute("DELETE FROM ipo.portfolio WHERE offering_id IN (SELECT offering_id FROM ipo.offerings WHERE player_id='p_c5_auction')")
cur.execute("DELETE FROM ipo.bids WHERE offering_id IN (SELECT offering_id FROM ipo.offerings WHERE player_id='p_c5_auction')")
cur.execute("DELETE FROM ipo.offerings WHERE player_id='p_c5_auction'")
cur.execute("DELETE FROM players.consent_releases WHERE player_id='p_c5_auction'")
cur.execute("DELETE FROM players.players WHERE player_id='p_c5_auction'")
for u in bidders + [extra_bidder]:
    cur.execute("DELETE FROM ledger.entries WHERE account_id IN (SELECT account_id FROM ledger.accounts WHERE user_id=%s)", (u,))
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE user_id=%s", (u,))
    cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s", (u,))
    cur.execute("DELETE FROM public.profiles WHERE user_id=%s", (u,))
    cur.execute("DELETE FROM auth.users WHERE id=%s", (u,))
cur.execute("DELETE FROM ledger.transactions WHERE transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries WHERE transaction_id IS NOT NULL)")
cur.execute("DELETE FROM ledger.idempotency_keys WHERE key LIKE 'c5_%'")
cur.execute("DELETE FROM audit.events WHERE source IN ('sessions','ipo','ledger') AND occurred_at > now() - interval '10 minutes'")
cur.execute("""UPDATE ledger.accounts SET balance_cached =
                 coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0),
                 version=version+1, updated_at=now()
               WHERE user_id=%s::uuid""", (treasury_uid,))

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL:
    sys.exit(1)
PY
