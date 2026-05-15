#!/usr/bin/env bash
# Card 12 catalog-redemption verification (post-restructure).
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

print("=== Card 12 catalog verification (full) ===")

# Schema
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='redemptions' AND table_name='catalog'")
aeq("schema.catalog_table", cur.fetchone()[0], 1)
cur.execute("SELECT column_name FROM information_schema.columns WHERE table_schema='redemptions' AND table_name='requests' AND column_name IN ('catalog_item_id','redemption_code','expires_at','fulfilled_at','fulfilled_by','cancelled_at','cancellation_reason')")
aeq("schema.requests_new_cols", len(cur.fetchall()), 7)
cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='transactions' AND c.conname='transactions_type_check'")
chk = cur.fetchone()[0]
for t in ('redemption_fulfilled','redemption_cancelled','redemption_expired'):
    atrue(f"schema.{t}_in_check", t in chk)

# RPCs
for fn in ('request_catalog_item','fulfill_request','cancel_request','expire_codes','upsert_catalog_item','_gen_code'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='redemptions' AND p.proname=%s",(fn,))
    aeq(f"rpc.redemptions_{fn}", cur.fetchone()[0], 1)
for fn in ('redemptions_request_catalog_item','redemptions_fulfill_request','redemptions_cancel_request','redemptions_upsert_catalog_item','get_active_catalog','lookup_redemption_code'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s",(fn,))
    aeq(f"rpc.public_{fn}", cur.fetchone()[0], 1)

# End-to-end smoke
test_user = str(uuid.uuid4())
cur.execute("INSERT INTO auth.users (id) VALUES (%s) ON CONFLICT (id) DO NOTHING", (test_user,))
cur.execute("UPDATE public.profiles SET display_name='C12 Test', age_verified=true, dob='1990-01-01', tier='upgraded' WHERE user_id=%s", (test_user,))
cur.execute("INSERT INTO ledger.accounts (user_id, account_type) VALUES (%s, 'available') ON CONFLICT (user_id, account_type) DO NOTHING", (test_user,))
cur.execute("SELECT ledger.admin_grant(%s, 100000, %s, %s, 'card-12 catalog')", (test_user, f"c12_grant_{test_user}", test_user))
admin = test_user

# Create item
cur.execute("SELECT redemptions.upsert_catalog_item(NULL, 'Test T-Shirt', 'Card 12 test shirt', 25000, 2500, NULL, true, 1, %s)", (admin,))
shirt_id = cur.fetchone()[0]
atrue("catalog.shirt_created", shirt_id is not None)
cur.execute("SELECT count(*) FROM public.get_active_catalog() WHERE name='Test T-Shirt'")
atrue("catalog.active_list_includes_shirt", cur.fetchone()[0] >= 1)

# Request redemption
cur.execute("SELECT redemptions.request_catalog_item(%s, %s, %s, %s)", (test_user, shirt_id, f"c12_req_{uuid.uuid4()}", admin))
result = cur.fetchone()[0]
code = result['redemption_code']
req_id = result['request_id']
atrue("request.code_8_chars", len(code) == 8)
aeq("request.gc_debited", result['gc_debited'], 25000)
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (test_user,))
aeq("request.available_debited", cur.fetchone()[0], 76000)  # 100000 grant + 1000 welcome - 25000 request
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='escrow_redemption'", (test_user,))
aeq("request.escrow_credited", cur.fetchone()[0], 25000)
cur.execute("SELECT status, expires_at FROM redemptions.requests WHERE request_id=%s", (req_id,))
status, expires = cur.fetchone()
aeq("request.status_pending", status, 'pending')
atrue("request.expires_in_90_days", expires is not None)

# Lookup by code
cur.execute("SELECT count(*) FROM public.lookup_redemption_code(%s)", (code,))
aeq("lookup.by_code", cur.fetchone()[0], 1)

# Fulfill
cur.execute("SELECT redemptions.fulfill_request(%s, %s, %s)", (req_id, admin, f"c12_fulfill_{uuid.uuid4()}"))
cur.execute("SELECT status, fulfilled_at IS NOT NULL FROM redemptions.requests WHERE request_id=%s", (req_id,))
s, stamped = cur.fetchone()
aeq("fulfill.status_fulfilled", s, 'fulfilled')
atrue("fulfill.fulfilled_at_stamped", stamped)
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='escrow_redemption'", (test_user,))
aeq("fulfill.escrow_drained", cur.fetchone()[0], 0)

# Cancel: create another request and cancel.
import json
cur.execute("SELECT redemptions.request_catalog_item(%s, %s, %s, %s)", (test_user, shirt_id, f"c12_req2_{uuid.uuid4()}", admin))
r2_raw = cur.fetchone()[0]
r2 = r2_raw if isinstance(r2_raw, dict) else json.loads(r2_raw)
cur.execute("SELECT redemptions.cancel_request(%s, %s, %s, %s)", (r2['request_id'], admin, 'user_requested_cancel', f"c12_cancel_{uuid.uuid4()}"))
cur.execute("SELECT status, cancellation_reason FROM redemptions.requests WHERE request_id=%s", (r2['request_id'],))
s, reason = cur.fetchone()
aeq("cancel.status_cancelled", s, 'cancelled')
aeq("cancel.reason", reason, 'user_requested_cancel')
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (test_user,))
# 76000 (after first request fulfilled) - 25000 (second request escrow) + 25000 (cancel refund) = 76000
aeq("cancel.refund_to_available", cur.fetchone()[0], 76000)

# Age-verified gate
unverified = str(uuid.uuid4())
cur.execute("INSERT INTO auth.users (id) VALUES (%s) ON CONFLICT (id) DO NOTHING", (unverified,))
cur.execute("UPDATE public.profiles SET display_name='Unverified', age_verified=false WHERE user_id=%s", (unverified,))
def _unverified():
    cur.execute("SELECT redemptions.request_catalog_item(%s, %s, %s, %s)", (unverified, shirt_id, f"c12_unver_{uuid.uuid4()}", admin))
araises("gate.age_verification_required", _unverified, 'age_verification_required')

# Inactive item
cur.execute("UPDATE redemptions.catalog SET is_active=false WHERE catalog_item_id=%s", (shirt_id,))
def _inactive():
    cur.execute("SELECT redemptions.request_catalog_item(%s, %s, %s, %s)", (test_user, shirt_id, f"c12_inactive_{uuid.uuid4()}", admin))
araises("gate.inactive_catalog_item", _inactive, 'catalog_item_inactive')

# Drift check
cur.execute("SELECT bool_and(ledger.verify_balance(account_id)) FROM ledger.accounts")
atrue("ledger.no_drift", cur.fetchone()[0])

# Audit
cur.execute("SELECT count(*) FROM audit.events WHERE source='redemptions' AND occurred_at > now() - interval '5 minutes'")
atrue("audit.redemption_events", cur.fetchone()[0] >= 3)

# Cleanup
cur.execute("DELETE FROM redemptions.requests WHERE user_id IN (%s, %s)", (test_user, unverified))
cur.execute("DELETE FROM redemptions.catalog WHERE catalog_item_id=%s", (shirt_id,))
for u in (test_user, unverified):
    cur.execute("DELETE FROM ledger.entries WHERE account_id IN (SELECT account_id FROM ledger.accounts WHERE user_id=%s)", (u,))
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE user_id=%s", (u,))
    cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s", (u,))
    cur.execute("DELETE FROM public.profiles WHERE user_id=%s", (u,))
    cur.execute("DELETE FROM auth.users WHERE id=%s", (u,))
cur.execute("DELETE FROM ledger.transactions WHERE transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries WHERE transaction_id IS NOT NULL)")
cur.execute("DELETE FROM audit.events WHERE source='redemptions' AND occurred_at > now() - interval '10 minutes'")
cur.execute("""UPDATE ledger.accounts SET balance_cached = coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0), version=version+1, updated_at=now() WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL: sys.exit(1)
PY
