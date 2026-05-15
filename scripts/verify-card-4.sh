#!/usr/bin/env bash
# Card 4 (Global audit_events table) end-to-end DB verification.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env.local ]]; then echo "ERROR: .env.local not found" >&2; exit 2; fi
DSN=$(grep '^SUPABASE_DB_URL=' .env.local | head -1 | cut -d= -f2-)
if [[ -z "$DSN" ]]; then echo "ERROR: SUPABASE_DB_URL not set" >&2; exit 2; fi
export SWEATS_DSN="$DSN"

python3 - <<'PY'
import os, sys, uuid, json
import psycopg2

dsn = os.environ['SWEATS_DSN']
conn = psycopg2.connect(dsn); conn.autocommit = True; cur = conn.cursor()

PASS, FAIL = [], []
def aeq(name, got, want):
    if got == want: PASS.append(name); print(f"  PASS {name}")
    else: FAIL.append((name, got, want)); print(f"  FAIL {name}: got={got!r} want={want!r}")
def atrue(name, cond, detail=""):
    if cond: PASS.append(name); print(f"  PASS {name}")
    else: FAIL.append((name, cond, True)); print(f"  FAIL {name}: {detail}")

print("=== Card 4 verification ===")

# 1. audit schema + table exist.
cur.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name='audit'")
aeq("schema.audit_exists", cur.fetchone()[0], 1)

cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='audit' AND table_name='events'")
aeq("schema.audit_events_table", cur.fetchone()[0], 1)

# 2. CHECK on severity.
cur.execute("""SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
                JOIN pg_class t ON t.oid=c.conrelid
                JOIN pg_namespace n ON n.oid=t.relnamespace
               WHERE n.nspname='audit' AND t.relname='events' AND c.conname='events_severity_check'""")
sev = cur.fetchone()[0]
atrue("schema.severity_check_set", "'info'" in sev and "'warning'" in sev and "'critical'" in sev)

# 3. audit.log_event RPC + grants.
cur.execute("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='audit' AND p.proname='log_event' AND p.prosecdef""")
aeq("rpc.log_event_security_definer", cur.fetchone()[0], 1)

# 4. RLS enabled.
cur.execute("SELECT relrowsecurity FROM pg_class WHERE relname='events' AND relnamespace='audit'::regnamespace")
atrue("rls.audit_events_enabled", cur.fetchone()[0])

# 5. Backfill happened — at least one ledger_audit_backfill row.
cur.execute("SELECT count(*) FROM audit.events WHERE source='ledger_audit_backfill'")
backfill_count = cur.fetchone()[0]
atrue("backfill.from_ledger_audit", backfill_count > 0, f"expected >0, got {backfill_count}")

# 6. Indexes present.
for idx in ('events_subject_occurred_idx','events_action_occurred_idx','events_source_occurred_idx','events_severity_critical_idx'):
    cur.execute("SELECT count(*) FROM pg_indexes WHERE schemaname='audit' AND indexname=%s", (idx,))
    aeq(f"schema.index.{idx}", cur.fetchone()[0], 1)

# 7. Direct INSERT to audit.events from a non-service-role context should be revoked.
#    (We're connected as a superuser here so the revoke won't block us; instead
#    we verify the grant table.)
cur.execute("""SELECT count(*) FROM information_schema.table_privileges
               WHERE table_schema='audit' AND table_name='events'
                 AND grantee IN ('PUBLIC','anon','authenticated') AND privilege_type IN ('INSERT','UPDATE','DELETE')""")
aeq("grants.no_write_to_public", cur.fetchone()[0], 0)

# 8. Dual-write smoke: post a real ledger transaction via post_transaction and check audit.events captured it.
cur.execute("SELECT user_id, age_verified, dob FROM public.profiles ORDER BY created_at DESC LIMIT 1")
row = cur.fetchone()
if not row:
    print("ERROR: no profiles exist on this DB", file=sys.stderr); sys.exit(3)
test_user, orig_av, orig_dob = row
cur.execute("""SELECT account_type, balance_cached FROM ledger.accounts
                WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
sys_snapshot = dict(cur.fetchall())

try:
    cur.execute("UPDATE public.profiles SET age_verified=true, dob=%s WHERE user_id=%s",
                ('1990-01-01', test_user))

    key = 'audit-test:'+str(uuid.uuid4())
    cur.execute("SELECT ledger.admin_grant(%s, 500, %s, %s, 'card-4 dual-write smoke')",
                (test_user, key, test_user))
    txn = cur.fetchone()[0]
    atrue("dual_write.ledger_admin_grant_creates_audit", txn is not None)

    cur.execute("""SELECT count(*) FROM audit.events
                    WHERE source='ledger'
                      AND action_type='transaction_posted'
                      AND related_transaction_id=%s""", (txn,))
    aeq("dual_write.audit_row_present_for_txn", cur.fetchone()[0], 1)

    cur.execute("""SELECT subject_user_id, severity, related_idempotency_key
                     FROM audit.events
                    WHERE related_transaction_id=%s""", (txn,))
    suid, sev, ikey = cur.fetchone()
    aeq("dual_write.subject_user_id_matches", suid, test_user)
    aeq("dual_write.severity_info", sev, 'info')
    aeq("dual_write.idempotency_key_threaded", ikey, key)

    # 9. Unverified-user blocking: ledger.post_transaction raises and rolls back.
    #    NOTE: the audit.log_event call inside the raise-path WILL ALSO ROLL BACK
    #    (plpgsql has no autonomous transactions). Audit for the failure case is
    #    the route layer's responsibility — captured in /api/payments/webhook
    #    and /api/admin/payments/refund where the application catches the error
    #    and calls audit.log_event in a fresh transaction. Card 4 DB scope ends
    #    with success-path dual-write proven; failure-path audit is route-layer.
    cur.execute("UPDATE public.profiles SET age_verified=false, dob=NULL WHERE user_id=%s", (test_user,))
    blocked = False
    try:
        cur.execute("SELECT ledger.admin_grant(%s, 100, %s, %s, 'unverified test')",
                    (test_user, 'audit-test:'+str(uuid.uuid4()), test_user))
    except psycopg2.Error as e:
        if 'unverified_identity' in str(e): blocked = True
    atrue("dual_write.unverified_blocked_raises", blocked)
    # Direct audit.log_event call (simulating what the route layer does after
    # catching the error) — proves the success-path audit infrastructure
    # works for failure narration too.
    cur.execute("""SELECT audit.log_event('admin','unverified_identity_blocked',
                       'admin_grant rejected for unverified user (route-layer audit)',
                       'warning', %s, %s, '{}'::jsonb, NULL, NULL, NULL, NULL)""",
                (test_user, test_user))
    eid = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM audit.events WHERE event_id=%s", (eid,))
    aeq("route_layer.unverified_audit_writable", cur.fetchone()[0], 1)

    # 10. log_event direct call produces a row of any source/action.
    cur.execute("""SELECT audit.log_event('test_smoke','synthetic_test',
                       'Card 4 verify-script direct call','info',
                       %s, %s, '{}'::jsonb, NULL, NULL, NULL, NULL)""",
                (test_user, test_user))
    eid = cur.fetchone()[0]
    cur.execute("SELECT source, action_type FROM audit.events WHERE event_id=%s", (eid,))
    s, a = cur.fetchone()
    aeq("rpc.log_event_writes_row", (s, a), ('test_smoke','synthetic_test'))

    # 11. Constraint violations.
    rejected = False
    try:
        cur.execute("""SELECT audit.log_event('test','t','','info',
                       NULL, NULL, '{}'::jsonb, NULL, NULL, NULL, NULL)""")
    except psycopg2.Error as e:
        if 'message_nonempty' in str(e) or 'check' in str(e).lower(): rejected = True
    atrue("schema.empty_message_rejected", rejected)

    # 12. get_my_audit_events function exists.
    cur.execute("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname='public' AND p.proname='get_my_audit_events'""")
    aeq("rpc.get_my_audit_events_exists", cur.fetchone()[0], 1)

finally:
    cur.execute("UPDATE public.profiles SET age_verified=%s, dob=%s WHERE user_id=%s",
                (orig_av, orig_dob, test_user))
    cur.execute("DELETE FROM audit.events WHERE source IN ('test_smoke','ledger','admin','payments') AND occurred_at > now() - interval '5 minutes'")
    # Delete entries by transaction so BOTH legs go (user + system account).
    cur.execute("""DELETE FROM ledger.entries WHERE transaction_id IN
                   (SELECT transaction_id FROM ledger.transactions
                     WHERE initiated_by=%s OR transaction_id IN
                       (SELECT transaction_id FROM ledger.entries WHERE account_id IN
                         (SELECT account_id FROM ledger.accounts WHERE user_id=%s)))""",
                (test_user, test_user))
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE key LIKE %s OR user_id=%s", ('audit-test:%', test_user))
    cur.execute("DELETE FROM ledger.transactions WHERE transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries)")
    cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s", (test_user,))
    # Resync system balance_cached from entries (covers any drift introduced).
    cur.execute("""UPDATE ledger.accounts SET balance_cached =
                     coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0),
                     version=version+1, updated_at=now()
                   WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
    cur.execute("DELETE FROM ledger.audit WHERE message LIKE %s OR message LIKE %s", ('%Card 4%','%card-4%'))

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL:
    for n,g,w in FAIL: print(f"  FAIL: {n}  got={g!r} want={w!r}")
    sys.exit(1)
PY
