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

print("=== Card 17 verification ===")

# Schema
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='players' AND table_name='consent_releases'")
aeq("schema.consent_releases_table", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name='analytics'")
aeq("schema.analytics_schema", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='analytics' AND table_name='events'")
aeq("schema.analytics_events_table", cur.fetchone()[0], 1)

# RPCs
for fn in ('has_active_consent','record_consent','revoke_consent'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='players' AND p.proname=%s",(fn,))
    aeq(f"rpc.players_{fn}", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='analytics' AND p.proname='track'")
aeq("rpc.analytics_track", cur.fetchone()[0], 1)
for fn in ('players_has_active_consent','players_record_consent','players_revoke_consent'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s",(fn,))
    aeq(f"rpc.public_{fn}", cur.fetchone()[0], 1)

# Trigger present
cur.execute("SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='ipo' AND c.relname='offerings' AND t.tgname='trg_require_player_consent'")
aeq("trigger.require_player_consent", cur.fetchone()[0], 1)

# Consent flow
test_player = 'p_c17_test'
cur.execute("INSERT INTO players.players (player_id, display_name, sport, status) VALUES (%s,'C17 Test','poker','active') ON CONFLICT (player_id) DO UPDATE SET status='active'", (test_player,))

# Without consent: offering INSERT should be blocked.
def _no_consent():
    cur.execute("""INSERT INTO ipo.offerings (player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, opens_at, closes_at)
                   VALUES (%s, 'C17', 10, 10, 100, now()-interval '1 minute', now()+interval '1 hour')""", (test_player,))
araises("gate.no_consent_blocks_offering", _no_consent, 'player_consent_missing')

# Record consent.
admin = str(uuid.uuid4())
cur.execute("SELECT players.record_consent(%s, 'v1.0', 'clickwrap', '203.0.113.5', NULL, %s)", (test_player, admin))
consent_id = cur.fetchone()[0]
atrue("consent.recorded", consent_id is not None)

cur.execute("SELECT players.has_active_consent(%s)", (test_player,))
atrue("consent.has_active_true", cur.fetchone()[0])

# Now offering INSERT succeeds.
cur.execute("""INSERT INTO ipo.offerings (player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, opens_at, closes_at)
               VALUES (%s, 'C17', 10, 10, 100, now()-interval '1 minute', now()+interval '1 hour')
               RETURNING offering_id""", (test_player,))
oid = cur.fetchone()[0]
atrue("gate.consent_unblocks_offering", oid is not None)

# Revoke consent.
cur.execute("SELECT players.revoke_consent(%s, 'test_revoke', %s)", (test_player, admin))
aeq("consent.revoke_count", cur.fetchone()[0], 1)
cur.execute("SELECT players.has_active_consent(%s)", (test_player,))
aeq("consent.has_active_false_after_revoke", cur.fetchone()[0], False)

# Analytics: signup emits user_signup event.
new_user = str(uuid.uuid4())
cur.execute("INSERT INTO auth.users (id) VALUES (%s)", (new_user,))
cur.execute("SELECT count(*) FROM analytics.events WHERE event_name='user_signup' AND user_id=%s", (new_user,))
aeq("analytics.user_signup_emitted", cur.fetchone()[0], 1)

# Track manual event.
cur.execute("SELECT analytics.track('test_event', %s, %s::jsonb, NULL, NULL)", (new_user, '{"key": "value"}'))
ev_id = cur.fetchone()[0]
cur.execute("SELECT event_name, properties->>'key' FROM analytics.events WHERE event_id=%s", (ev_id,))
name, val = cur.fetchone()
aeq("analytics.track_event_name", name, 'test_event')
aeq("analytics.track_properties_passthrough", val, 'value')

# Cleanup
cur.execute("DELETE FROM ipo.offerings WHERE offering_id=%s", (oid,))
cur.execute("DELETE FROM players.consent_releases WHERE player_id=%s", (test_player,))
cur.execute("DELETE FROM players.players WHERE player_id=%s", (test_player,))
cur.execute("DELETE FROM analytics.events WHERE user_id=%s", (new_user,))
cur.execute("DELETE FROM ledger.entries WHERE account_id IN (SELECT account_id FROM ledger.accounts WHERE user_id=%s)", (new_user,))
cur.execute("DELETE FROM ledger.idempotency_keys WHERE user_id=%s", (new_user,))
cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s", (new_user,))
cur.execute("DELETE FROM public.profiles WHERE user_id=%s", (new_user,))
cur.execute("DELETE FROM auth.users WHERE id=%s", (new_user,))
cur.execute("DELETE FROM ledger.transactions WHERE transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries WHERE transaction_id IS NOT NULL)")
cur.execute("DELETE FROM audit.events WHERE source IN ('players','sessions','platform_settings','profiles','ledger') AND occurred_at > now() - interval '10 minutes'")
cur.execute("""UPDATE ledger.accounts SET balance_cached = coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0), version=version+1, updated_at=now() WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")

cur.execute("SELECT bool_and(ledger.verify_balance(account_id)) FROM ledger.accounts")
atrue("ledger.no_drift", cur.fetchone()[0])

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL: sys.exit(1)
PY
