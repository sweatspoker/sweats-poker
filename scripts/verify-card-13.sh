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
def aeq(n, g, w):
    if g == w: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n, g, w)); print(f"  FAIL {n}: got={g!r} want={w!r}")
def atrue(n, c, d=""):
    if c: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n, c, True)); print(f"  FAIL {n}: {d}")
def araises(n, fn, want_substr):
    try:
        fn(); FAIL.append((n, "no_raise", want_substr)); print(f"  FAIL {n}: expected raise containing {want_substr!r}")
    except Exception as e:
        if want_substr in str(e): PASS.append(n); print(f"  PASS {n}")
        else: FAIL.append((n, str(e), want_substr)); print(f"  FAIL {n}: got={e!r} want_substr={want_substr!r}")

print("=== Card 13 verification ===")

# --- schema additions ---
cur.execute("""
SELECT column_name FROM information_schema.columns
 WHERE table_schema='ipo' AND table_name='offerings'
   AND column_name IN ('session_state','buy_in_amount_minor','player_photo_url','stream_url',
                       'ipo_clearing_price_minor','session_started_at','settled_at',
                       'final_chip_stack_minor','final_share_value_minor',
                       'halted_at','halt_reason','cancelled_at','cancellation_reason')
""")
cols = sorted([r[0] for r in cur.fetchall()])
aeq("schema.new_columns_count", len(cols), 13)

# --- state machine CHECK constraint ---
cur.execute("""SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
 JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
 WHERE n.nspname='ipo' AND t.relname='offerings' AND c.conname='offerings_session_state_check'""")
row = cur.fetchone()
atrue("schema.session_state_check", row is not None and "'draft'" in row[0] and "'settled'" in row[0])

# --- RPCs ---
for fn in ('transition_session','assert_session_transition','_sync_session_state_from_clearing'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ipo' AND p.proname=%s", (fn,))
    aeq(f"rpc.ipo_{fn}_exists", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='settlements' AND p.proname='distribute_with_state'")
aeq("rpc.distribute_with_state_exists", cur.fetchone()[0], 1)
for fn in ('sessions_transition','settlements_distribute_with_state'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s", (fn,))
    aeq(f"rpc.public_{fn}_exists", cur.fetchone()[0], 1)

# --- trigger ---
cur.execute("""SELECT count(*) FROM pg_trigger t
 JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='ipo' AND c.relname='offerings' AND t.tgname='trg_sync_session_state'""")
aeq("trigger.sync_session_state_exists", cur.fetchone()[0], 1)

# --- pick / create a test player; create a draft offering ---
cur.execute("""INSERT INTO players.players (player_id, display_name, sport, status)
 VALUES ('p_c13_test', 'Card 13 Test', 'poker', 'active')
 ON CONFLICT (player_id) DO UPDATE SET status='active'""")
cur.execute("SELECT players.record_consent('p_c13_test', 'v1.0', 'operator_attestation', NULL, NULL, NULL)")

cur.execute("""INSERT INTO ipo.offerings (
  player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor,
  opens_at, closes_at)
 VALUES ('p_c13_test','Card 13 Test', 1000, 1000, 100,
   now() - interval '1 minute', now() + interval '1 hour')
 RETURNING offering_id, clearing_status, session_state, buy_in_amount_minor""")
oid, cstatus, sstate, buyin = cur.fetchone()
aeq("draft.clearing_status", cstatus, 'pending')
aeq("draft.session_state", sstate, 'draft')
aeq("draft.buy_in_amount_minor", buyin, 1000)

# --- promote via direct clearing_status update (simulates first-bid promotion) ---
cur.execute("UPDATE ipo.offerings SET clearing_status='open' WHERE offering_id=%s RETURNING session_state", (oid,))
aeq("trigger.pending_to_open", cur.fetchone()[0], 'ipo_open')

cur.execute("UPDATE ipo.offerings SET clearing_status='clearing' WHERE offering_id=%s RETURNING session_state", (oid,))
aeq("trigger.open_to_clearing", cur.fetchone()[0], 'ipo_closing')

cur.execute("UPDATE ipo.offerings SET clearing_status='closed' WHERE offering_id=%s RETURNING session_state, session_started_at IS NOT NULL", (oid,))
sstate, started = cur.fetchone()
aeq("trigger.clearing_to_closed", sstate, 'active')
atrue("trigger.session_started_at_stamped", started)

# --- post-IPO transitions via transition_session ---
admin = str(uuid.uuid4())
cur.execute("SELECT ipo.transition_session(%s, 'halted', %s::uuid, 'manual_halt_test')", (oid, admin))
cur.execute("SELECT session_state, halted_at IS NOT NULL, halt_reason FROM ipo.offerings WHERE offering_id=%s", (oid,))
sstate, halted_stamped, reason = cur.fetchone()
aeq("transition.active_to_halted", sstate, 'halted')
atrue("transition.halted_at_stamped", halted_stamped)
aeq("transition.halt_reason", reason, 'manual_halt_test')

cur.execute("SELECT ipo.transition_session(%s, 'active', %s::uuid, NULL)", (oid, admin))
cur.execute("SELECT session_state FROM ipo.offerings WHERE offering_id=%s", (oid,))
aeq("transition.halted_to_active", cur.fetchone()[0], 'active')

cur.execute("SELECT ipo.transition_session(%s, 'settling', %s::uuid, 'manual_settle_test')", (oid, admin))
cur.execute("SELECT session_state FROM ipo.offerings WHERE offering_id=%s", (oid,))
aeq("transition.active_to_settling", cur.fetchone()[0], 'settling')

cur.execute("SELECT ipo.transition_session(%s, 'settled', %s::uuid, 'manual_settle_complete')", (oid, admin))
cur.execute("SELECT session_state, settled_at IS NOT NULL FROM ipo.offerings WHERE offering_id=%s", (oid,))
sstate, settled_stamped = cur.fetchone()
aeq("transition.settling_to_settled", sstate, 'settled')
atrue("transition.settled_at_stamped", settled_stamped)

# --- terminal state rejection ---
def _terminal_settled():
    cur.execute("SELECT ipo.transition_session(%s, 'cancelled', %s::uuid, 'should_fail')", (oid, admin))
araises("transition.settled_is_terminal", _terminal_settled, 'terminal_state')

# --- invalid transition ---
cur.execute("""INSERT INTO ipo.offerings (
  player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor,
  opens_at, closes_at)
 VALUES ('p_c13_test','Card 13 Test', 100, 100, 100,
   now() - interval '1 minute', now() + interval '1 hour')
 RETURNING offering_id""")
oid2 = cur.fetchone()[0]
def _invalid():
    cur.execute("SELECT ipo.transition_session(%s, 'settling', %s::uuid, 'should_fail')", (oid2, admin))
araises("transition.draft_to_settling_rejected", _invalid, 'invalid_transition')

# --- cancellation from draft ---
cur.execute("SELECT ipo.transition_session(%s, 'cancelled', %s::uuid, 'no_show')", (oid2, admin))
cur.execute("SELECT session_state, cancelled_at IS NOT NULL, cancellation_reason FROM ipo.offerings WHERE offering_id=%s", (oid2,))
sstate, cancelled_stamped, reason = cur.fetchone()
aeq("transition.draft_to_cancelled", sstate, 'cancelled')
atrue("transition.cancelled_at_stamped", cancelled_stamped)
aeq("transition.cancellation_reason", reason, 'no_show')

# --- audit events emitted ---
cur.execute("""SELECT count(*) FROM audit.events
 WHERE source='sessions' AND metadata->>'session_id' IN (%s,%s)""", (str(oid), str(oid2)))
atrue("audit.session_events_present", cur.fetchone()[0] >= 4)

# --- cleanup ---
cur.execute("DELETE FROM ipo.offerings WHERE offering_id IN (%s,%s)", (oid, oid2))
cur.execute("DELETE FROM players.consent_releases WHERE player_id='p_c13_test'")
cur.execute("DELETE FROM players.players WHERE player_id='p_c13_test'")

print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
sys.exit(0 if not FAIL else 1)
PY
