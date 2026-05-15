#!/usr/bin/env bash
# Card 5 (IPO mechanic) end-to-end verification.

set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .env.local ]]; then echo "ERROR: .env.local not found" >&2; exit 2; fi
DSN=$(grep '^SUPABASE_DB_URL=' .env.local | head -1 | cut -d= -f2-)
if [[ -z "$DSN" ]]; then echo "ERROR: SUPABASE_DB_URL not set" >&2; exit 2; fi
export SWEATS_DSN="$DSN"

python3 - <<'PY'
import os, sys, uuid, json, psycopg2
dsn=os.environ['SWEATS_DSN']
conn=psycopg2.connect(dsn); conn.autocommit=True; cur=conn.cursor()
PASS,FAIL=[],[]
def aeq(n,g,w):
    if g==w: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,g,w)); print(f"  FAIL {n}: got={g!r} want={w!r}")
def atrue(n,c,d=""):
    if c: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,c,True)); print(f"  FAIL {n}: {d}")

print("=== Card 5 verification ===")

# 1. Schema invariants.
cur.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name='ipo'")
aeq("schema.ipo_exists", cur.fetchone()[0], 1)
for tbl in ('offerings','portfolio'):
    cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='ipo' AND table_name=%s",(tbl,))
    aeq(f"schema.ipo_{tbl}_table", cur.fetchone()[0], 1)

# 2. New escrow_ipo_bid account_type accepted.
cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='accounts' AND c.conname='accounts_type_check'")
atrue("schema.escrow_ipo_bid_in_check", 'escrow_ipo_bid' in cur.fetchone()[0])

# 3. New transaction_types in CHECK.
cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='transactions' AND c.conname='transactions_type_check'")
chk = cur.fetchone()[0]
for t in ('ipo_bid_placed','ipo_bid_cleared','ipo_bid_refunded'):
    atrue(f"schema.{t}_in_check", t in chk)

# 4. Generated offering_id column.
cur.execute("SELECT is_generated, generation_expression FROM information_schema.columns WHERE table_schema='ledger' AND table_name='transactions' AND column_name='offering_id'")
g, e = cur.fetchone()
aeq("schema.offering_id_generated", g, 'ALWAYS')
atrue("schema.offering_id_extracts_from_metadata", 'metadata' in e and 'offering_id' in e)

cur.execute("SELECT count(*) FROM pg_indexes WHERE schemaname='ledger' AND indexname='transactions_offering_idx'")
aeq("schema.offering_id_partial_index", cur.fetchone()[0], 1)

# 5. RLS + grants.
for tbl in ('offerings','portfolio'):
    cur.execute(f"SELECT relrowsecurity FROM pg_class WHERE relname='{tbl}' AND relnamespace='ipo'::regnamespace")
    atrue(f"rls.{tbl}_enabled", cur.fetchone()[0])

# 6. Functions present.
for fn in ('place_bid','clear_offering'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ipo' AND p.proname=%s AND p.prosecdef",(fn,))
    aeq(f"rpc.ipo_{fn}_security_definer", cur.fetchone()[0], 1)
for fn in ('ipo_place_bid','ipo_clear_offering','get_my_portfolio'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s",(fn,))
    aeq(f"rpc.public_{fn}_exists", cur.fetchone()[0], 1)

# 7. End-to-end smoke: create an offering, place 3 bids (2 full + 1 partial), clear, verify portfolio.
cur.execute("SELECT user_id, age_verified, dob FROM public.profiles ORDER BY created_at DESC LIMIT 1")
row = cur.fetchone()
if not row: sys.exit("no profiles exist")
test_user, orig_av, orig_dob = row
cur.execute("""SELECT account_type, balance_cached FROM ledger.accounts
                WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
sys_snapshot = dict(cur.fetchall())

try:
    cur.execute("UPDATE public.profiles SET age_verified=true, dob=%s WHERE user_id=%s", ('1990-01-01', test_user))

    # Grant test user 10000 minor units (100 GC).
    grant_key = 'ipo-smoke:'+str(uuid.uuid4())
    cur.execute("SELECT ledger.admin_grant(%s, 10000, %s, %s, 'card-5 smoke prep')", (test_user, grant_key, test_user))

    # Card 6 introduced players.players FK on ipo.offerings — seed the test player first.
    cur.execute("""INSERT INTO players.players (player_id, display_name, sport, status)
                   VALUES ('player-test-1','Test Player','poker','active')
                   ON CONFLICT (player_id) DO UPDATE SET status='active'""")

    # Create an offering: 5 shares at 1000 minor units (10 GC) per share.
    cur.execute("""INSERT INTO ipo.offerings (player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, opens_at, closes_at, created_by)
                   VALUES (%s, %s, 5, 5, 1000, now() - interval '1 minute', now() + interval '1 hour', %s)
                   RETURNING offering_id""",
                ('player-test-1', 'Test Player', test_user))
    offering_id = cur.fetchone()[0]
    atrue("offerings.created", offering_id is not None)

    # Place 3 bids. Use a second account_id for the system test (we'll use test_user for both bids — same user, three separate idempotency keys).
    bid_keys = []
    bid_ids = []
    for shares in (2, 2, 3):
        k = 'bid:'+str(uuid.uuid4())
        bid_keys.append(k)
        cur.execute("SELECT ipo.place_bid(%s, %s, %s, %s, %s, '{}'::jsonb)",
                    (test_user, offering_id, shares, k, test_user))
        bid_ids.append(cur.fetchone()[0])
    aeq("bids.three_placed", len(bid_ids), 3)

    # Escrow balance should be (2+2+3)*1000 = 7000.
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='escrow_ipo_bid'", (test_user,))
    aeq("bids.escrow_total", cur.fetchone()[0], 7000)

    # Available debited by 7000.
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (test_user,))
    avail = cur.fetchone()[0]
    aeq("bids.available_debited", avail, 10000 - 7000)  # 3000 left from 10000 grant

    # Generated offering_id column populated.
    cur.execute("SELECT count(*) FROM ledger.transactions WHERE offering_id=%s AND transaction_type='ipo_bid_placed'", (offering_id,))
    aeq("bids.offering_id_column_populated", cur.fetchone()[0], 3)

    # Now clear the offering: 5 shares total, bids are 2+2+3 in FCFS order → first two fully fill (4 shares), boundary bid gets 1 share + 2 refunded.
    cur.execute("SELECT ipo.clear_offering(%s, %s)", (offering_id, test_user))
    summary = cur.fetchone()[0]
    aeq("clearing.shares_filled", summary['shares_filled'], 5)
    aeq("clearing.shares_unfilled", summary['shares_unfilled'], 0)
    aeq("clearing.bids_filled", summary['bids_filled'], 3)  # all three got at least some
    aeq("clearing.bids_refunded", summary['bids_refunded'], 1)  # boundary bid had a partial refund

    # Status closed.
    cur.execute("SELECT clearing_status, shares_remaining FROM ipo.offerings WHERE offering_id=%s",(offering_id,))
    s, r = cur.fetchone()
    aeq("offering.status_closed", s, 'closed')
    aeq("offering.shares_remaining_zero", r, 0)

    # Portfolio has shares_held=5.
    cur.execute("SELECT shares_held FROM ipo.portfolio WHERE user_id=%s AND offering_id=%s",(test_user, offering_id))
    aeq("portfolio.shares_held", cur.fetchone()[0], 5)

    # Escrow drained: 5 * 1000 = 5000 to treasury, 2 * 1000 = 2000 refunded → escrow=0, available=3000+2000=5000.
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='escrow_ipo_bid'",(test_user,))
    aeq("post_clear.escrow_drained", cur.fetchone()[0], 0)
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'",(test_user,))
    aeq("post_clear.available_refilled", cur.fetchone()[0], 5000)

    # platform_treasury increased by 5000.
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid AND account_type='platform_treasury'")
    treas = cur.fetchone()[0]
    # Treasury delta = +5000 (fill) - 10000 (admin_grant from treasury) = -5000 from baseline 0
    aeq("post_clear.treasury_net_delta", treas - sys_snapshot.get('platform_treasury', 0), -5000)

    # Idempotency: re-clearing returns already_closed.
    cur.execute("SELECT ipo.clear_offering(%s, %s)", (offering_id, test_user))
    s2 = cur.fetchone()[0]
    aeq("clearing.idempotent_already_closed", s2.get('status'), 'already_closed')

    # ipo_bid_placed cannot happen on a closed offering.
    rejected = False
    try:
        cur.execute("SELECT ipo.place_bid(%s, %s, 1, %s, %s, '{}'::jsonb)",
                    (test_user, offering_id, 'bid-after-close:'+str(uuid.uuid4()), test_user))
    except psycopg2.Error as e:
        if 'offering_not_accepting_bids' in str(e): rejected = True
    atrue("bids.rejected_after_close", rejected)

    # Drift check.
    cur.execute("SELECT bool_and(ledger.verify_balance(account_id)) FROM ledger.accounts")
    atrue("ledger.no_drift", cur.fetchone()[0])

    # Audit rows for IPO events.
    cur.execute("SELECT count(*) FROM audit.events WHERE source='ipo' AND occurred_at > now() - interval '5 minutes'")
    atrue("audit.ipo_events_present", cur.fetchone()[0] >= 5, "expected at least 5 IPO audit rows (3 placed + clears/refunds + offering_cleared)")

finally:
    cur.execute("UPDATE public.profiles SET age_verified=%s, dob=%s WHERE user_id=%s", (orig_av, orig_dob, test_user))
    cur.execute("DELETE FROM audit.events WHERE source IN ('ipo','ledger','admin') AND occurred_at > now() - interval '10 minutes'")
    # Delete all IPO + admin entries for this test user.
    cur.execute("""DELETE FROM ledger.entries WHERE transaction_id IN
                   (SELECT transaction_id FROM ledger.transactions WHERE initiated_by=%s OR offering_id IS NOT NULL)""", (test_user,))
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE key LIKE %s OR key LIKE %s OR key LIKE %s OR user_id=%s",
                ('ipo:%','ipo-smoke:%','bid:%', test_user))
    cur.execute("DELETE FROM ipo.portfolio WHERE user_id=%s", (test_user,))
    cur.execute("DELETE FROM ipo.offerings WHERE created_by=%s OR player_id LIKE %s", (test_user, 'player-test-%'))
    cur.execute("DELETE FROM players.players WHERE player_id LIKE %s", ('player-test-%',))
    cur.execute("DELETE FROM ledger.transactions WHERE transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries)")
    cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s", (test_user,))
    cur.execute("""UPDATE ledger.accounts SET balance_cached =
                     coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0),
                     version=version+1, updated_at=now()
                   WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
    cur.execute("DELETE FROM ledger.audit WHERE message LIKE %s OR message LIKE %s", ('%card-5%','%Card 5%'))

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL:
    for n,g,w in FAIL: print(f"  FAIL: {n}  got={g!r} want={w!r}")
    sys.exit(1)
PY
