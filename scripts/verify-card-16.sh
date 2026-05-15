#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DSN=$(grep '^SUPABASE_DB_URL=' .env.local | head -1 | cut -d= -f2-)
export SWEATS_DSN="$DSN"

python3 - <<'PY'
import os, sys, uuid, json, psycopg2
conn = psycopg2.connect(os.environ['SWEATS_DSN']); conn.autocommit = True
cur = conn.cursor()
PASS, FAIL = [], []
def aeq(n,g,w):
    if g==w: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,g,w)); print(f"  FAIL {n}: got={g!r} want={w!r}")
def atrue(n,c,d=""):
    if c: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,c,True)); print(f"  FAIL {n}: {d}")

print("=== Card 16 verification ===")

cur.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name='platform'")
aeq("schema.platform_exists", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='platform' AND table_name='settings'")
aeq("schema.settings_table", cur.fetchone()[0], 1)

for fn in ('get_setting','upsert_setting'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='platform' AND p.proname=%s", (fn,))
    aeq(f"rpc.platform_{fn}", cur.fetchone()[0], 1)
for fn in ('platform_get_setting','platform_upsert_setting','platform_list_settings'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s", (fn,))
    aeq(f"rpc.public_{fn}", cur.fetchone()[0], 1)

# Default seeds
for key in ('welcome_bonus_minor','tier_upgrade_threshold_minor','session_min_minutes','pre_settle_freeze_minutes','ipo_default_face_value_minor','ipo_minimum_bid_minor'):
    cur.execute("SELECT count(*) FROM platform.settings WHERE setting_key=%s", (key,))
    aeq(f"seed.{key}", cur.fetchone()[0], 1)

# Round-trip: read + write + read.
admin = str(uuid.uuid4())
cur.execute("SELECT platform.get_setting('welcome_bonus_minor', '0'::jsonb)")
default = int(cur.fetchone()[0])
aeq("get_setting.default", default, 1000)

cur.execute("SELECT platform.upsert_setting('welcome_bonus_minor', %s::jsonb, 'Tunable welcome bonus', %s)", (json.dumps(500), admin))
cur.execute("SELECT platform.get_setting('welcome_bonus_minor', '0'::jsonb)")
aeq("upsert_setting.updated_value", int(cur.fetchone()[0]), 500)

# Restore.
cur.execute("SELECT platform.upsert_setting('welcome_bonus_minor', %s::jsonb, NULL, %s)", (json.dumps(1000), admin))

# New setting key.
test_key = f"c16_test_{uuid.uuid4().hex[:8]}"
cur.execute("SELECT platform.upsert_setting(%s, %s::jsonb, 'Card 16 test', %s)", (test_key, json.dumps({"x": 1, "y": "z"}), admin))
cur.execute("SELECT setting_value FROM platform.settings WHERE setting_key=%s", (test_key,))
val = cur.fetchone()[0]
if isinstance(val, str): val = json.loads(val)
aeq("upsert_setting.new_key_value", val, {"x": 1, "y": "z"})

cur.execute("DELETE FROM platform.settings WHERE setting_key=%s", (test_key,))

# Audit
cur.execute("SELECT count(*) FROM audit.events WHERE source='platform_settings' AND occurred_at > now() - interval '5 minutes'")
atrue("audit.platform_settings_emitted", cur.fetchone()[0] >= 2)

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL: sys.exit(1)
PY

echo ""
echo "=== HTTP route smoke (presence) ==="
for route in api/admin/sessions/halt api/admin/sessions/no-show api/admin/sessions/freeze api/admin/settings api/admin/catalog/upsert; do
    if [[ -f "src/app/$route/route.ts" ]]; then
        echo "  PASS route.exists.$route"
    else
        echo "  FAIL route.missing.$route"
        exit 1
    fi
done
echo "=== Route presence OK ==="
