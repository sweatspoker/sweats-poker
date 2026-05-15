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

print("=== Card 9 verification ===")
for sch in ('sales','referrals'):
    cur.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name=%s",(sch,))
    aeq(f"schema.{sch}_exists", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='sales' AND table_name='campaigns'")
aeq("schema.campaigns_table", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='referrals' AND table_name='codes'")
aeq("schema.codes_table", cur.fetchone()[0], 1)

for fn in ('complete_founding_purchase',):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='sales' AND p.proname=%s AND p.prosecdef",(fn,))
    aeq(f"rpc.sales_{fn}_definer", cur.fetchone()[0], 1)
for fn in ('create_code',):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='referrals' AND p.proname=%s AND p.prosecdef",(fn,))
    aeq(f"rpc.referrals_{fn}_definer", cur.fetchone()[0], 1)
for fn in ('sales_complete_founding_purchase','referrals_create_code','get_active_campaign','lookup_referral'):
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

    # Seed a campaign with two tiers.
    tiers=json.dumps([
        {"tier_key":"starter","dollars_usd":5,"base_gc":50,"bonus_gc":10,"max_per_user":1},
        {"tier_key":"founder","dollars_usd":100,"base_gc":1000,"bonus_gc":500,"max_per_user":1}
    ])
    cur.execute("""INSERT INTO sales.campaigns (code, display_name, status, starts_at, ends_at, tiers)
                   VALUES ('card9-test','Card9 Test Campaign','active', now()-interval '1 hour', now()+interval '1 day', %s::jsonb)
                   RETURNING campaign_id""",(tiers,))
    campaign_id=cur.fetchone()[0]
    atrue("campaign.created", campaign_id is not None)

    # Test 1: founding purchase without referral.
    event_id='ev-'+str(uuid.uuid4())
    cur.execute("SELECT sales.complete_founding_purchase(%s,%s,%s,'starter','synthetic',NULL,%s,'{}'::jsonb)",
                (event_id, u, campaign_id, u))
    txn_id=cur.fetchone()[0]
    atrue("purchase.returns_txn", txn_id is not None)

    # Buyer should have 50 base + 10 bonus = 60 GC = 6000 minor.
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'",(u,))
    aeq("purchase.buyer_credited_60gc", cur.fetchone()[0], 6000)

    # Campaign sold_minor advanced by 50 GC base = 5000.
    cur.execute("SELECT sold_minor FROM sales.campaigns WHERE campaign_id=%s",(campaign_id,))
    aeq("campaign.sold_advanced", cur.fetchone()[0], 5000)

    # purchase_source stamped.
    cur.execute("SELECT purchase_source FROM ledger.transactions WHERE transaction_id=%s",(txn_id,))
    aeq("purchase.source_synthetic", cur.fetchone()[0], 'synthetic')

    # Metadata flags founding.
    cur.execute("SELECT metadata->>'is_founding_purchase' FROM ledger.transactions WHERE transaction_id=%s",(txn_id,))
    aeq("purchase.metadata_founding", cur.fetchone()[0], 'true')

    # Audit emitted.
    cur.execute("SELECT count(*) FROM audit.events WHERE source='sales' AND action_type='founding_purchase_completed'")
    atrue("audit.founding_purchase", cur.fetchone()[0] >= 1)

    # Test 2: referral. Create code owned by another user (use platform sentinel + create profile).
    # For test simplicity, use buyer's account as both owner and try to redeem — should be rejected (owner==redeemer).
    cur.execute("SELECT referrals.create_code('TEST-REF-1',%s,2000,1500,NULL,%s)",(u,campaign_id))
    aeq("referral.create_returns_code", cur.fetchone()[0], 'TEST-REF-1')

    # Self-redeem (owner_user_id == p_user_id): referral should be ignored, no bonus.
    event_id2='ev-'+str(uuid.uuid4())
    cur.execute("SELECT sales.complete_founding_purchase(%s,%s,%s,'starter','synthetic','TEST-REF-1',%s,'{}'::jsonb)",
                (event_id2, u, campaign_id, u))
    txn_id2=cur.fetchone()[0]
    cur.execute("SELECT redeemed_at FROM referrals.codes WHERE code='TEST-REF-1'")
    aeq("referral.self_redeem_blocked", cur.fetchone()[0], None)
    # Buyer total = previous 6000 + 6000 (60 more GC) = 12000.
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'",(u,))
    aeq("referral.self_redeem_no_extra_credit", cur.fetchone()[0], 12000)

    # Inactive campaign → rejected.
    cur.execute("UPDATE sales.campaigns SET status='paused' WHERE campaign_id=%s",(campaign_id,))
    rejected=False
    try:
        cur.execute("SELECT sales.complete_founding_purchase(%s,%s,%s,'starter','synthetic',NULL,%s,'{}'::jsonb)",
                    ('ev-'+str(uuid.uuid4()), u, campaign_id, u))
    except psycopg2.Error as e:
        if 'campaign_not_active' in str(e): rejected=True
    atrue("purchase.paused_campaign_rejected", rejected)
    cur.execute("UPDATE sales.campaigns SET status='active' WHERE campaign_id=%s",(campaign_id,))

    # Unknown tier rejected.
    rejected=False
    try:
        cur.execute("SELECT sales.complete_founding_purchase(%s,%s,%s,'NONEXIST','synthetic',NULL,%s,'{}'::jsonb)",
                    ('ev-'+str(uuid.uuid4()), u, campaign_id, u))
    except psycopg2.Error as e:
        if 'tier_not_found' in str(e): rejected=True
    atrue("purchase.unknown_tier_rejected", rejected)

    # Anon shim returns the active campaign.
    cur.execute("SELECT count(*) FROM public.get_active_campaign() WHERE campaign_id=%s",(campaign_id,))
    aeq("public.get_active_campaign_visible", cur.fetchone()[0], 1)

    # lookup_referral returns the test code.
    cur.execute("SELECT count(*) FROM public.lookup_referral('TEST-REF-1') WHERE code='TEST-REF-1'")
    aeq("public.lookup_referral_visible", cur.fetchone()[0], 1)

    # Idempotency: replay returns same txn.
    cur.execute("SELECT sales.complete_founding_purchase(%s,%s,%s,'starter','synthetic',NULL,%s,'{}'::jsonb)",
                (event_id, u, campaign_id, u))
    aeq("idempotency.replay", cur.fetchone()[0], txn_id)

    # Drift.
    cur.execute("SELECT bool_and(ledger.verify_balance(account_id)) FROM ledger.accounts")
    atrue("ledger.no_drift", cur.fetchone()[0])

finally:
    cur.execute("DELETE FROM audit.events WHERE source IN ('sales','referrals','ledger') AND occurred_at > now() - interval '10 minutes'")
    cur.execute("DELETE FROM referrals.codes WHERE code LIKE %s",('TEST-REF-%',))
    cur.execute("DELETE FROM sales.campaigns WHERE code LIKE %s",('card9-test%',))
    cur.execute("""DELETE FROM ledger.entries WHERE transaction_id IN
                   (SELECT transaction_id FROM ledger.transactions WHERE metadata->>'is_founding_purchase'='true' OR initiated_by=%s)""",(u,))
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE key LIKE %s OR user_id=%s",('founding:%',u,))
    cur.execute("DELETE FROM ledger.transactions WHERE metadata->>'is_founding_purchase'='true' OR (initiated_by=%s AND transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries))",(u,))
    cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s",(u,))
    for atype, bal in sys_snapshot.items():
        cur.execute("""UPDATE ledger.accounts SET balance_cached=%s, version=0
                        WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid AND account_type=%s""",(bal,atype))
    cur.execute("""UPDATE ledger.accounts SET balance_cached=coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0), version=version+1, updated_at=now() WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
    cur.execute("UPDATE public.profiles SET age_verified=false WHERE user_id=%s",(u,))

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL:
    for n,g,w in FAIL: print(f"  FAIL: {n}  got={g!r} want={w!r}")
    sys.exit(1)
PY
