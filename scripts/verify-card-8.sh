#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DSN=$(grep '^SUPABASE_DB_URL=' .env.local | head -1 | cut -d= -f2-)
export SWEATS_DSN="$DSN"

python3 - <<'PY'
import os, sys, uuid, psycopg2
conn=psycopg2.connect(os.environ['SWEATS_DSN']); conn.autocommit=True; cur=conn.cursor()
PASS,FAIL=[],[]
def aeq(n,g,w):
    if g==w: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,g,w)); print(f"  FAIL {n}: got={g!r} want={w!r}")
def atrue(n,c,d=""):
    if c: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,c,True)); print(f"  FAIL {n}: {d}")

print("=== Card 8 verification ===")
cur.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name='support'")
aeq("schema.support_exists", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='support' AND table_name='tickets'")
aeq("schema.tickets_table", cur.fetchone()[0], 1)

cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='tickets' AND c.conname='tickets_status_check'")
sc=cur.fetchone()[0]
for s in ('open','triage','in_progress','resolved','closed','wont_fix'):
    atrue(f"schema.status_{s}", s in sc)

for fn in ('open_ticket','update_ticket','resolve_with_ledger_action'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='support' AND p.proname=%s AND p.prosecdef",(fn,))
    aeq(f"rpc.support_{fn}_definer", cur.fetchone()[0], 1)
for fn in ('support_open_ticket','support_update_ticket','support_resolve_with_ledger','get_my_tickets'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s",(fn,))
    aeq(f"rpc.public_{fn}_exists", cur.fetchone()[0], 1)

cur.execute("SELECT relrowsecurity FROM pg_class WHERE relname='tickets' AND relnamespace='support'::regnamespace")
atrue("rls.tickets_enabled", cur.fetchone()[0])

cur.execute("SELECT user_id FROM public.profiles ORDER BY created_at DESC LIMIT 1")
row=cur.fetchone()
if not row: sys.exit("no profiles")
u=row[0]

try:
    cur.execute("SELECT support.open_ticket(%s,'dispute','Test ticket','Body here','urgent',NULL,NULL,NULL,NULL,'{}'::jsonb)",(u,))
    tid=cur.fetchone()[0]
    atrue("open.returns_uuid", tid is not None)
    cur.execute("SELECT status, severity FROM support.tickets WHERE ticket_id=%s",(tid,))
    s,sv=cur.fetchone()
    aeq("open.default_status", s, 'open')
    aeq("open.severity_propagated", sv, 'urgent')
    cur.execute("SELECT count(*) FROM audit.events WHERE source='support' AND action_type='ticket_opened' AND metadata->>'ticket_id'=%s",(str(tid),))
    aeq("audit.ticket_opened", cur.fetchone()[0], 1)

    # Update status to triage.
    cur.execute("SELECT (support.update_ticket(%s,%s,'triage',NULL,NULL,NULL,'{}'::jsonb)).status",(tid,u))
    aeq("update.status_triage", cur.fetchone()[0], 'triage')

    # In progress.
    cur.execute("SELECT (support.update_ticket(%s,%s,'in_progress',NULL,%s,NULL,'{}'::jsonb)).assignee_user_id",(tid,u,u))
    aeq("update.assignee", cur.fetchone()[0], u)

    # Resolve.
    cur.execute("SELECT (support.update_ticket(%s,%s,'resolved',NULL,NULL,'fixed by admin','{}'::jsonb)).status",(tid,u))
    aeq("update.status_resolved", cur.fetchone()[0], 'resolved')
    cur.execute("SELECT resolved_at FROM support.tickets WHERE ticket_id=%s",(tid,))
    atrue("update.resolved_at_set", cur.fetchone()[0] is not None)

    # Close.
    cur.execute("SELECT (support.update_ticket(%s,%s,'closed',NULL,NULL,NULL,'{}'::jsonb)).status",(tid,u))
    aeq("update.status_closed", cur.fetchone()[0], 'closed')

    # Reopen within window.
    cur.execute("SELECT (support.update_ticket(%s,%s,'in_progress',NULL,NULL,'reopening','{}'::jsonb)).status",(tid,u))
    aeq("reopen.within_window_ok", cur.fetchone()[0], 'in_progress')
    cur.execute("SELECT reopen_count FROM support.tickets WHERE ticket_id=%s",(tid,))
    aeq("reopen.count_incremented", cur.fetchone()[0], 1)

    # Force a past close to test window-expired reopen.
    cur.execute("UPDATE support.tickets SET status='closed', closed_at=now()-interval '40 days' WHERE ticket_id=%s",(tid,))
    rejected=False
    try:
        cur.execute("SELECT (support.update_ticket(%s,%s,'open',NULL,NULL,'late reopen','{}'::jsonb)).status",(tid,u))
    except psycopg2.Error as e:
        if 'reopen_window_expired' in str(e): rejected=True
    atrue("reopen.outside_window_blocked", rejected)

    # Resolve with ledger action.
    cur.execute("UPDATE support.tickets SET status='open', closed_at=NULL WHERE ticket_id=%s",(tid,))
    cur.execute("UPDATE public.profiles SET age_verified=true, dob='1990-01-01' WHERE user_id=%s",(u,))
    cur.execute("SELECT ledger.admin_grant(%s, 100, %s, %s, 'support resolution test')",(u,'sup-grant:'+str(uuid.uuid4()),u))
    txn=cur.fetchone()[0]
    cur.execute("SELECT support.resolve_with_ledger_action(%s,%s,%s,'resolved via grant')",(tid,txn,u))
    cur.execute("SELECT metadata->>'resolution_ticket_id' FROM ledger.transactions WHERE transaction_id=%s",(txn,))
    aeq("resolve.ledger_metadata_stamped", cur.fetchone()[0], str(tid))
    cur.execute("SELECT count(*) FROM audit.events WHERE action_type='ticket_resolved_via_ledger' AND metadata->>'ticket_id'=%s",(str(tid),))
    aeq("resolve.audit_row_emitted", cur.fetchone()[0], 1)
    cur.execute("SELECT status FROM support.tickets WHERE ticket_id=%s",(tid,))
    aeq("resolve.ticket_status_resolved", cur.fetchone()[0], 'resolved')

    # Invalid kind rejected.
    rejected=False
    try:
        cur.execute("SELECT support.open_ticket(%s,'INVALID_KIND','Test',NULL,'normal',NULL,NULL,NULL,NULL,'{}'::jsonb)",(u,))
    except psycopg2.Error as e:
        if 'kind_check' in str(e): rejected=True
    atrue("open.invalid_kind_rejected", rejected)

finally:
    cur.execute("DELETE FROM support.tickets WHERE user_id=%s",(u,))
    cur.execute("DELETE FROM audit.events WHERE source='support' AND occurred_at > now() - interval '5 minutes'")
    cur.execute("DELETE FROM audit.events WHERE source IN ('ledger','admin') AND occurred_at > now() - interval '5 minutes'")
    cur.execute("DELETE FROM ledger.entries WHERE transaction_id IN (SELECT transaction_id FROM ledger.transactions WHERE initiated_by=%s)",(u,))
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE key LIKE %s",('sup-grant:%',))
    cur.execute("DELETE FROM ledger.transactions WHERE initiated_by=%s AND transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries)",(u,))
    cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s",(u,))
    cur.execute("""UPDATE ledger.accounts SET balance_cached=coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0), version=version+1, updated_at=now() WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
    cur.execute("UPDATE public.profiles SET age_verified=false WHERE user_id=%s",(u,))

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL:
    for n,g,w in FAIL: print(f"  FAIL: {n}  got={g!r} want={w!r}")
    sys.exit(1)
PY
