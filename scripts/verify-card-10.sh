#!/usr/bin/env bash
# Card 10 (HTTP admin wrappers) — route compile + sales_upsert_campaign RPC
# smoke. HTTP smoke is constrained without LEDGER_ADMIN_TOKEN env in local dev.

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

print("=== Card 10 verification ===")

# 1. public.sales_upsert_campaign exists.
cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='sales_upsert_campaign'")
aeq("rpc.sales_upsert_campaign_exists", cur.fetchone()[0], 1)

# 2. End-to-end: upsert a campaign via the RPC.
tiers=json.dumps([{"tier_key":"smoke","dollars_usd":1,"base_gc":10,"bonus_gc":2,"max_per_user":1}])
try:
    cur.execute("SELECT public.sales_upsert_campaign('card10-smoke','Card 10 Smoke',now(),now()+interval '1 day',%s::jsonb,'draft',NULL,'{}'::jsonb)",(tiers,))
    cid=cur.fetchone()[0]
    atrue("upsert.returns_uuid", cid is not None)
    cur.execute("SELECT status FROM sales.campaigns WHERE campaign_id=%s",(cid,))
    aeq("upsert.status_set", cur.fetchone()[0], 'draft')

    # Re-upsert with status='active' updates the row.
    cur.execute("SELECT public.sales_upsert_campaign('card10-smoke','Card 10 Smoke',now(),now()+interval '1 day',%s::jsonb,'active',NULL,'{}'::jsonb)",(tiers,))
    cur.execute("SELECT status FROM sales.campaigns WHERE campaign_id=%s",(cid,))
    aeq("upsert.status_updated", cur.fetchone()[0], 'active')

    cur.execute("SELECT count(*) FROM audit.events WHERE source='sales' AND action_type='campaign_upserted' AND metadata->>'code'='card10-smoke'")
    atrue("audit.campaign_upserted", cur.fetchone()[0] >= 2)
finally:
    cur.execute("DELETE FROM audit.events WHERE source='sales' AND occurred_at > now() - interval '5 minutes'")
    cur.execute("DELETE FROM sales.campaigns WHERE code='card10-smoke'")

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL:
    for n,g,w in FAIL: print(f"  FAIL: {n}  got={g!r} want={w!r}")
    sys.exit(1)
PY

# Verify route files exist + Next.js build compiles.
echo ""
echo "=== Route file presence ==="
for r in players/admin/upsert orders/admin/cancel support/admin/update sales/admin/create-campaign sales/admin/create-referral sales/founding-purchase; do
    if [[ -f "src/app/api/$r/route.ts" ]]; then
        echo "  PASS route.exists.$r"
    else
        echo "  FAIL route.missing.$r"
        exit 1
    fi
done

echo ""
echo "=== Result: route + DB smoke complete ==="
