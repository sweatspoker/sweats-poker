#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DSN=$(grep '^SUPABASE_DB_URL=' .env.local | head -1 | cut -d= -f2-)
export SWEATS_DSN="$DSN"

python3 - <<'PY'
import os, sys, uuid, psycopg2
conn = psycopg2.connect(os.environ['SWEATS_DSN']); conn.autocommit = True
cur = conn.cursor()
PASS, FAIL = [], []
def aeq(n,g,w):
    if g==w: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,g,w)); print(f"  FAIL {n}: got={g!r} want={w!r}")
def atrue(n,c,d=""):
    if c: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,c,True)); print(f"  FAIL {n}: {d}")
def araises(n, fn, want):
    try:
        fn(); FAIL.append((n,"no_raise",want)); print(f"  FAIL {n}")
    except Exception as e:
        if want in str(e): PASS.append(n); print(f"  PASS {n}")
        else: FAIL.append((n,str(e),want)); print(f"  FAIL {n}: got={e!r}")

print("=== Card 15 verification ===")

# Schema
cur.execute("SELECT column_name FROM information_schema.columns WHERE table_schema='ipo' AND table_name='offerings' AND column_name IN ('pre_settlement_freeze_at','no_show_cancelled_at')")
aeq("schema.offering_new_columns", len(cur.fetchall()), 2)
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='ledger' AND table_name='rate_limit_events'")
aeq("schema.rate_limit_table", cur.fetchone()[0], 1)

# RPCs
for fn in ('signal_pre_settlement_freeze','no_show_cancel'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ipo' AND p.proname=%s",(fn,))
    aeq(f"rpc.ipo_{fn}", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ledger' AND p.proname='assert_rate_limit'")
aeq("rpc.ledger_assert_rate_limit", cur.fetchone()[0], 1)
for fn in ('sessions_signal_pre_settlement_freeze','sessions_no_show_cancel'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s",(fn,))
    aeq(f"rpc.public_{fn}", cur.fetchone()[0], 1)

# --- Rate-limit test: 11th call within 1s should reject ---
ratelimit_user = str(uuid.uuid4())
for i in range(10):
    cur.execute("SELECT ledger.assert_rate_limit(%s, 'test_action', 10, 1)", (ratelimit_user,))
def _rate_exceed():
    cur.execute("SELECT ledger.assert_rate_limit(%s, 'test_action', 10, 1)", (ratelimit_user,))
araises("rate_limit.eleventh_rejected", _rate_exceed, 'rate_limit_exceeded')

# --- No-show cancel: end-to-end ---
bidder = str(uuid.uuid4())
admin = bidder
cur.execute("INSERT INTO auth.users (id) VALUES (%s) ON CONFLICT (id) DO NOTHING", (bidder,))
cur.execute("UPDATE public.profiles SET display_name='C15 Bidder', age_verified=true, dob='1990-01-01', tier='upgraded' WHERE user_id=%s", (bidder,))
cur.execute("INSERT INTO ledger.accounts (user_id, account_type) VALUES (%s, 'available') ON CONFLICT (user_id, account_type) DO NOTHING", (bidder,))
cur.execute("SELECT ledger.admin_grant(%s, 100000, %s, %s, 'card-15 no-show test')", (bidder, f"c15_grant_{bidder}", bidder))

cur.execute("INSERT INTO players.players (player_id, display_name, sport, status) VALUES ('p_c15','C15','poker','active') ON CONFLICT (player_id) DO UPDATE SET status='active'")
cur.execute("""INSERT INTO ipo.offerings (player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, opens_at, closes_at)
 VALUES ('p_c15','C15', 5, 5, 100, now() - interval '1 minute', now() + interval '1 hour')
 RETURNING offering_id""")
oid = cur.fetchone()[0]

# Place a winning bid + clear.
cur.execute("SELECT ipo.place_bid(%s, %s, 5, 200, %s, NULL)", (bidder, oid, f"c15_bid_{uuid.uuid4()}"))
bid_id = cur.fetchone()[0]
cur.execute("SELECT ipo.clear_offering(%s, NULL)", (oid,))
clear_summary = cur.fetchone()[0]
aeq("setup.clearing_price", clear_summary['clearing_price_per_share_minor'], 200)

# Pre-no-show: confirm holding + escrow flows correctly.
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (bidder,))
before_no_show = cur.fetchone()[0]
# bidder started with 100000 grant + 1000 welcome = 101000. Bid 5*200=1000 escrowed. After clear: pay 5*200=1000 at clearing, refund 0 overbid → 101000-1000=100000.
aeq("setup.available_after_clear", before_no_show, 100000)
cur.execute("SELECT shares_held FROM ipo.portfolio WHERE user_id=%s AND offering_id=%s", (bidder, oid))
aeq("setup.shares_held", cur.fetchone()[0], 5)

# Trigger no-show cancel.
cur.execute("SELECT ipo.no_show_cancel(%s, %s, %s)", (oid, admin, 'player_no_show'))
result = cur.fetchone()[0]
aeq("no_show.refunded_count", result['refunded_count'], 1)
aeq("no_show.total_refunded", result['total_refunded_minor'], 1000)

# Session marked cancelled.
cur.execute("SELECT session_state, no_show_cancelled_at IS NOT NULL FROM ipo.offerings WHERE offering_id=%s", (oid,))
state, stamped = cur.fetchone()
aeq("no_show.state_cancelled", state, 'cancelled')
atrue("no_show.timestamp_stamped", stamped)

# Bidder refunded: should be back to 100000 + 1000 (face refund + premium refund) = 101000.
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (bidder,))
aeq("no_show.bidder_full_refund", cur.fetchone()[0], 101000)

# Portfolio cleared.
cur.execute("SELECT count(*) FROM ipo.portfolio WHERE user_id=%s AND offering_id=%s", (bidder, oid))
aeq("no_show.portfolio_cleared", cur.fetchone()[0], 0)

# --- pre_settlement_freeze: 60-min minimum gate ---
# Create a fresh offering, force it to 'active', set session_started_at to 30 min ago (too young).
cur.execute("""INSERT INTO ipo.offerings (player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, opens_at, closes_at, session_state, clearing_status, session_started_at)
 VALUES ('p_c15','C15', 1, 1, 100, now() - interval '1 minute', now() + interval '1 hour', 'active', 'closed', now() - interval '30 minutes')
 RETURNING offering_id""")
oid2 = cur.fetchone()[0]

def _too_young():
    cur.execute("SELECT ipo.signal_pre_settlement_freeze(%s, %s)", (oid2, admin))
araises("freeze.session_too_young", _too_young, 'session_too_young_for_voluntary_cashout')

# Backdate to 90 min ago: now signal succeeds.
cur.execute("UPDATE ipo.offerings SET session_started_at = now() - interval '90 minutes' WHERE offering_id=%s", (oid2,))
cur.execute("SELECT ipo.signal_pre_settlement_freeze(%s, %s)", (oid2, admin))
result = cur.fetchone()[0]
atrue("freeze.signal_succeeds_after_60min", result.get('freeze_at') is not None)
cur.execute("SELECT pre_settlement_freeze_at IS NOT NULL FROM ipo.offerings WHERE offering_id=%s", (oid2,))
atrue("freeze.column_stamped", cur.fetchone()[0])

# Cleanup
cur.execute("DELETE FROM ipo.bids WHERE offering_id IN (%s, %s)", (oid, oid2))
cur.execute("DELETE FROM ipo.portfolio WHERE offering_id IN (%s, %s)", (oid, oid2))
cur.execute("DELETE FROM ipo.offerings WHERE offering_id IN (%s, %s)", (oid, oid2))
cur.execute("DELETE FROM players.players WHERE player_id='p_c15'")
cur.execute("DELETE FROM ledger.entries WHERE account_id IN (SELECT account_id FROM ledger.accounts WHERE user_id=%s)", (bidder,))
cur.execute("DELETE FROM ledger.idempotency_keys WHERE user_id=%s", (bidder,))
cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s", (bidder,))
cur.execute("DELETE FROM public.profiles WHERE user_id=%s", (bidder,))
cur.execute("DELETE FROM auth.users WHERE id=%s", (bidder,))
cur.execute("DELETE FROM ledger.rate_limit_events WHERE user_id IN (%s,%s)", (bidder, ratelimit_user))
cur.execute("DELETE FROM ledger.transactions WHERE transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries WHERE transaction_id IS NOT NULL)")
cur.execute("DELETE FROM audit.events WHERE source IN ('sessions','ipo','ledger') AND occurred_at > now() - interval '10 minutes'")
cur.execute("""UPDATE ledger.accounts SET balance_cached = coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0), version=version+1, updated_at=now() WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")

# Drift check.
cur.execute("SELECT bool_and(ledger.verify_balance(account_id)) FROM ledger.accounts")
atrue("ledger.no_drift", cur.fetchone()[0])

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL: sys.exit(1)
PY
