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

print("=== Card 12 verification ===")
cur.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name='redemptions'")
aeq("schema.redemptions_exists", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='redemptions' AND table_name='requests'")
aeq("schema.requests_table", cur.fetchone()[0], 1)

cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='transactions' AND c.conname='transactions_type_check'")
chk=cur.fetchone()[0]
for t in ('redemption_requested','redemption_paid'): atrue(f"schema.{t}_in_check", t in chk)

cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='accounts' AND c.conname='accounts_type_check'")
atrue("schema.escrow_redemption_in_check", 'escrow_redemption' in cur.fetchone()[0])

for fn in ('request_redemption','approve_and_pay','deny_request'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='redemptions' AND p.proname=%s AND p.prosecdef",(fn,))
    aeq(f"rpc.redemptions_{fn}_definer", cur.fetchone()[0], 1)
for fn in ('redemptions_request','redemptions_approve_and_pay','redemptions_deny','get_my_redemptions'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s",(fn,))
    aeq(f"rpc.public_{fn}_exists", cur.fetchone()[0], 1)

cur.execute("SELECT user_id FROM public.profiles ORDER BY created_at DESC LIMIT 1")
row=cur.fetchone()
if not row: sys.exit("no profiles")
u=row[0]
cur.execute("""SELECT account_type, balance_cached FROM ledger.accounts WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
sys_snapshot=dict(cur.fetchall())

try:
    # Grant initial balance + verify age + KYC.
    cur.execute("UPDATE public.profiles SET age_verified=true, dob='1990-01-01', kyc_status='verified' WHERE user_id=%s",(u,))
    cur.execute("SELECT ledger.admin_grant(%s, 5000, %s, %s, 'c12 prep')",(u,'c12-grant:'+str(uuid.uuid4()),u))

    # Test 1: unverified KYC rejected.
    cur.execute("UPDATE public.profiles SET kyc_status='none' WHERE user_id=%s",(u,))
    rejected=False
    try:
        cur.execute("SELECT public.redemptions_request(%s, 100, %s, '{}'::jsonb)",(u,'rej-'+str(uuid.uuid4())))
    except psycopg2.Error as e:
        if 'kyc_required_for_redemption' in str(e): rejected=True
    atrue("request.kyc_required_rejected", rejected)

    cur.execute("UPDATE public.profiles SET kyc_status='verified' WHERE user_id=%s",(u,))

    # Test 2: valid request → debits available, credits escrow.
    ev='rev-'+str(uuid.uuid4())
    cur.execute("SELECT public.redemptions_request(%s, 1000, %s, '{}'::jsonb)",(u,ev))
    rid=cur.fetchone()[0]
    atrue("request.returns_uuid", rid is not None)
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'",(u,))
    aeq("request.available_debited", cur.fetchone()[0], 4000)
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='escrow_redemption'",(u,))
    aeq("request.escrow_credited", cur.fetchone()[0], 1000)
    cur.execute("SELECT status FROM redemptions.requests WHERE request_id=%s",(rid,))
    aeq("request.status_requested", cur.fetchone()[0], 'requested')

    # Test 3: approve_and_pay → escrow → treasury.
    cur.execute("SELECT public.redemptions_approve_and_pay(%s, %s, 'stripe_payout', '{}'::jsonb)",(rid, u))
    pay_txn=cur.fetchone()[0]
    atrue("approve.returns_txn", pay_txn is not None)
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='escrow_redemption'",(u,))
    aeq("approve.escrow_drained", cur.fetchone()[0], 0)
    cur.execute("SELECT status, payment_destination FROM redemptions.requests WHERE request_id=%s",(rid,))
    s, p = cur.fetchone()
    aeq("approve.status_paid", s, 'paid')
    aeq("approve.dest_set", p, 'stripe_payout')

    # Test 4: deny a fresh request → escrow → back to available.
    ev2='rev2-'+str(uuid.uuid4())
    cur.execute("SELECT public.redemptions_request(%s, 500, %s, '{}'::jsonb)",(u,ev2))
    rid2=cur.fetchone()[0]
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'",(u,))
    pre_deny_avail = cur.fetchone()[0]
    cur.execute("SELECT public.redemptions_deny(%s, %s, 'test denial')",(rid2,u))
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'",(u,))
    aeq("deny.refunds_to_available", cur.fetchone()[0], pre_deny_avail + 500)
    cur.execute("SELECT status, denial_reason FROM redemptions.requests WHERE request_id=%s",(rid2,))
    s, dr = cur.fetchone()
    aeq("deny.status_denied", s, 'denied')
    aeq("deny.reason_set", dr, 'test denial')

    # Test 5: Re-approve an already-paid request rejected.
    rejected=False
    try:
        cur.execute("SELECT public.redemptions_approve_and_pay(%s, %s, 'check', '{}'::jsonb)",(rid, u))
    except psycopg2.Error as e:
        if 'request_not_payable' in str(e): rejected=True
    atrue("approve.double_pay_rejected", rejected)

    # Drift.
    cur.execute("SELECT bool_and(ledger.verify_balance(account_id)) FROM ledger.accounts")
    atrue("ledger.no_drift", cur.fetchone()[0])

    # Audit emitted.
    cur.execute("SELECT count(*) FROM audit.events WHERE source='redemptions'")
    atrue("audit.redemption_events", cur.fetchone()[0] >= 3)

finally:
    cur.execute("DELETE FROM audit.events WHERE source IN ('redemptions','ledger','admin') AND occurred_at > now() - interval '10 minutes'")
    cur.execute("DELETE FROM redemptions.requests WHERE user_id=%s",(u,))
    cur.execute("""DELETE FROM ledger.entries WHERE transaction_id IN
                   (SELECT transaction_id FROM ledger.transactions WHERE transaction_type IN ('redemption_requested','redemption_paid') OR initiated_by=%s)""",(u,))
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE key LIKE %s OR key LIKE %s OR user_id=%s",('redemption:%','c12-grant:%',u))
    cur.execute("DELETE FROM ledger.transactions WHERE transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries)")
    cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s",(u,))
    cur.execute("""UPDATE ledger.accounts SET balance_cached=coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0), version=version+1, updated_at=now() WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
    cur.execute("UPDATE public.profiles SET age_verified=false, kyc_status='none' WHERE user_id=%s",(u,))

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL:
    for n,g,w in FAIL: print(f"  FAIL: {n}  got={g!r} want={w!r}")
    sys.exit(1)
PY
