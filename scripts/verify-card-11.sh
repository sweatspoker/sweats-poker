#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DSN=$(grep '^SUPABASE_DB_URL=' .env.local | head -1 | cut -d= -f2-)
export SWEATS_DSN="$DSN"

python3 - <<'PY'
import os, sys, uuid, json, psycopg2
conn=psycopg2.connect(os.environ['SWEATS_DSN']); conn.autocommit=True; cur=conn.cursor()
PASS,FAIL=[],[]
def aeq(n,g,w):
    if g==w: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,g,w)); print(f"  FAIL {n}: got={g!r} want={w!r}")
def atrue(n,c,d=""):
    if c: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,c,True)); print(f"  FAIL {n}: {d}")

print("=== Card 11 verification ===")
cur.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name='settlements'")
aeq("schema.settlements_exists", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='settlements' AND table_name='events'")
aeq("schema.events_table", cur.fetchone()[0], 1)

cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='transactions' AND c.conname='transactions_type_check'")
atrue("schema.settlement_payout_in_check", 'settlement_payout' in cur.fetchone()[0])

for fn in ('distribute',):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='settlements' AND p.proname=%s AND p.prosecdef",(fn,))
    aeq(f"rpc.settlements_{fn}_definer", cur.fetchone()[0], 1)
for fn in ('settlements_distribute','settlements_create_event'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s",(fn,))
    aeq(f"rpc.public_{fn}_exists", cur.fetchone()[0], 1)

cur.execute("SELECT user_id FROM public.profiles ORDER BY created_at DESC LIMIT 1")
row=cur.fetchone()
if not row: sys.exit("no profiles")
u=row[0]
cur.execute("""SELECT account_type, balance_cached FROM ledger.accounts WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
sys_snapshot=dict(cur.fetchall())

try:
    cur.execute("UPDATE public.profiles SET age_verified=true, dob='1990-01-01' WHERE user_id=%s",(u,))

    # Seed a player + offering + portfolio row.
    pid='C11-PLAYER-'+str(uuid.uuid4())[:8]
    cur.execute("""INSERT INTO players.players (player_id, display_name, sport, status) VALUES (%s,'C11 Test','poker','active')""",(pid,))
    cur.execute("SELECT players.record_consent(%s, 'v1.0', 'operator_attestation', NULL, NULL, NULL)",(pid,))
    cur.execute("""INSERT INTO ipo.offerings (player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, opens_at, closes_at, created_by, clearing_status)
                   VALUES (%s,'C11 Test',10,0,1000, now()-interval '1 day', now()-interval '1 hour', %s, 'closed') RETURNING offering_id""",(pid,u))
    offering_id=cur.fetchone()[0]
    cur.execute("""INSERT INTO ipo.portfolio (user_id, offering_id, shares_held, weighted_avg_cost_minor, first_acquired_at)
                   VALUES (%s,%s,5,1000,now())""",(u,offering_id))

    # Create a settlement event (1000 minor total pool).
    cur.execute("SELECT public.settlements_create_event(%s, 1000, 'Test weekly pool', %s, %s, '{}'::jsonb)",(pid, offering_id, u))
    eid=cur.fetchone()[0]
    atrue("create.returns_uuid", eid is not None)

    # Distribute.
    cur.execute("SELECT public.settlements_distribute(%s,%s)",(eid,u))
    summary=cur.fetchone()[0]
    aeq("distribute.holders_paid", summary['holders_paid'], 1)
    # 5 shares of 10 outstanding (just our 5). Per-share minor = 1000/5 = 200. User gets 5*200 = 1000.
    aeq("distribute.total_paid", summary['total_paid_minor'], 1000)

    # User available credited.
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'",(u,))
    aeq("payout.user_credited", cur.fetchone()[0], 1000)

    # Status set to distributed.
    cur.execute("SELECT status FROM settlements.events WHERE settlement_event_id=%s",(eid,))
    aeq("settlement.status_distributed", cur.fetchone()[0], 'distributed')

    # Idempotent re-run returns already_distributed.
    cur.execute("SELECT public.settlements_distribute(%s,%s)",(eid,u))
    aeq("distribute.idempotent", cur.fetchone()[0]['status'], 'already_distributed')

    # Audit emitted.
    cur.execute("SELECT count(*) FROM audit.events WHERE source='settlements' AND action_type='settlement_distributed'")
    atrue("audit.settlement_distributed", cur.fetchone()[0] >= 1)

    # Drift.
    cur.execute("SELECT bool_and(ledger.verify_balance(account_id)) FROM ledger.accounts")
    atrue("ledger.no_drift", cur.fetchone()[0])

finally:
    cur.execute("DELETE FROM audit.events WHERE source IN ('settlements','ledger','admin') AND occurred_at > now() - interval '5 minutes'")
    cur.execute("DELETE FROM settlements.events WHERE player_id=%s",(pid,))
    cur.execute("""DELETE FROM ledger.entries WHERE transaction_id IN
                   (SELECT transaction_id FROM ledger.transactions WHERE transaction_type='settlement_payout')""")
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE key LIKE %s",('settlement:%',))
    cur.execute("DELETE FROM ledger.transactions WHERE transaction_type='settlement_payout'")
    cur.execute("DELETE FROM ipo.portfolio WHERE offering_id=%s",(offering_id,))
    cur.execute("DELETE FROM ipo.offerings WHERE offering_id=%s",(offering_id,))
    cur.execute("DELETE FROM players.consent_releases WHERE player_id=%s",(pid,))
    cur.execute("DELETE FROM players.players WHERE player_id=%s",(pid,))
    cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s",(u,))
    cur.execute("""UPDATE ledger.accounts SET balance_cached=coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0), version=version+1, updated_at=now() WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
    cur.execute("UPDATE public.profiles SET age_verified=false WHERE user_id=%s",(u,))

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL:
    for n,g,w in FAIL: print(f"  FAIL: {n}  got={g!r} want={w!r}")
    sys.exit(1)
PY
