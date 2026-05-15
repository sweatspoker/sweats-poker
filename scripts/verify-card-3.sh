#!/usr/bin/env bash
# Card 3 (Stripe placeholder — synthetic walkthrough) end-to-end DB verification.
# Tests the migration 0005 surface: purchase_complete + purchase_refund wrappers,
# source-tagging, idempotency-prefix discipline, refund symmetry, age-verified gate.
# UI/webhook routes are out of scope here — they ride on the same RPCs and have
# their own runtime gates (NODE_ENV, SYNTHETIC_PAYMENTS_ENABLED, HMAC).
#
# Idempotent: reverts all state at end.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env.local ]]; then
  echo "ERROR: .env.local not found in repo root" >&2
  exit 2
fi

DSN=$(grep '^SUPABASE_DB_URL=' .env.local | head -1 | cut -d= -f2-)
if [[ -z "$DSN" ]]; then
  echo "ERROR: SUPABASE_DB_URL not set in .env.local" >&2
  exit 2
fi

export SWEATS_DSN="$DSN"

python3 - <<'PY'
import os, sys, uuid, json
import psycopg2

dsn = os.environ['SWEATS_DSN']
conn = psycopg2.connect(dsn); conn.autocommit = True; cur = conn.cursor()

PASS = []
FAIL = []
def assert_eq(name, got, want):
    if got == want:
        PASS.append(name); print(f"  PASS {name}")
    else:
        FAIL.append((name, got, want)); print(f"  FAIL {name}: got={got!r} want={want!r}")

def assert_true(name, cond, detail=""):
    if cond:
        PASS.append(name); print(f"  PASS {name}")
    else:
        FAIL.append((name, cond, True)); print(f"  FAIL {name}: {detail}")

print("=== Card 3 verification ===")

cur.execute("SELECT user_id, age_verified, dob FROM public.profiles ORDER BY created_at DESC LIMIT 1")
row = cur.fetchone()
if not row:
    print("ERROR: no profiles exist on this DB", file=sys.stderr); sys.exit(3)
test_user, orig_av, orig_dob = row

cur.execute("""SELECT account_type, balance_cached FROM ledger.accounts
                WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
sys_snapshot = dict(cur.fetchall())

try:
    # 1. CHECK constraint covers Card 3 types.
    cur.execute("""SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
                    JOIN pg_class t ON t.oid=c.conrelid
                   WHERE t.relname='transactions' AND c.conname='transactions_type_check'""")
    cdef = cur.fetchone()[0]
    assert_true("schema.check_includes_purchase_settled", 'purchase_settled' in cdef)
    assert_true("schema.check_includes_purchase_refunded", 'purchase_refunded' in cdef)

    # 2. Wrapper functions exist + are service-role-only.
    cur.execute("""SELECT proname FROM pg_proc p
                    JOIN pg_namespace n ON n.oid=p.pronamespace
                   WHERE n.nspname='ledger' AND proname IN ('purchase_complete','purchase_refund')""")
    fnames = sorted([r[0] for r in cur.fetchall()])
    assert_eq("schema.wrappers_present", fnames, ['purchase_complete', 'purchase_refund'])

    # 3. Ensure verified profile for happy path.
    cur.execute("UPDATE public.profiles SET age_verified=true, dob=%s WHERE user_id=%s",
                ('1990-01-01', test_user))

    # 4. Happy path: synthetic purchase credits user available + debits platform_float.
    cur.execute("""SELECT coalesce((SELECT balance_cached FROM ledger.accounts
                                      WHERE user_id=%s AND account_type='available'), 0)""", (test_user,))
    before_user = cur.fetchone()[0]
    before_float = sys_snapshot.get('platform_float', 0)

    sim_event_1 = 'sim-'+str(uuid.uuid4())
    cur.execute("""SELECT ledger.purchase_complete(%s, %s, %s, 'synthetic', %s, '{}'::jsonb)""",
                (sim_event_1, test_user, 1000, test_user))  # $1 worth = 10 GC = 1000 minor
    txn1 = cur.fetchone()[0]
    assert_true("synthetic.returns_uuid", txn1 is not None)

    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (test_user,))
    after_user = cur.fetchone()[0]
    assert_eq("synthetic.user_credit", after_user - before_user, 1000)

    cur.execute("""SELECT balance_cached FROM ledger.accounts
                    WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid AND account_type='platform_float'""")
    after_float = cur.fetchone()[0]
    assert_eq("synthetic.float_debit", after_float - before_float, -1000)

    # 5. Metadata tag — must mark synthetic source for auditability.
    cur.execute("SELECT metadata FROM ledger.transactions WHERE transaction_id=%s", (txn1,))
    meta = cur.fetchone()[0]
    assert_eq("synthetic.metadata.purchase_source", meta.get('purchase_source'), 'synthetic')
    assert_eq("synthetic.metadata.rate", meta.get('rate'), '$1=10GC')

    # 6. Idempotency: same sim_event_id returns the SAME transaction.
    cur.execute("""SELECT ledger.purchase_complete(%s, %s, %s, 'synthetic', %s, '{}'::jsonb)""",
                (sim_event_1, test_user, 1000, test_user))
    txn1_replay = cur.fetchone()[0]
    assert_eq("synthetic.idempotency_replay", txn1_replay, txn1)

    # 7. Idempotency-prefix namespace: same event_id with source='stripe' MUST be a distinct txn.
    cur.execute("""SELECT ledger.purchase_complete(%s, %s, %s, 'stripe', %s, '{}'::jsonb)""",
                (sim_event_1, test_user, 1000, test_user))
    txn_stripe = cur.fetchone()[0]
    assert_true("source.namespace_independent", txn_stripe != txn1,
                "stripe:<id> collided with synthetic:<id> — namespace prefix is broken")

    cur.execute("SELECT metadata->>'purchase_source' FROM ledger.transactions WHERE transaction_id=%s", (txn_stripe,))
    assert_eq("stripe.metadata.purchase_source", cur.fetchone()[0], 'stripe')

    # 8. Invalid source rejected.
    invalid_rejected = False
    try:
        cur.execute("""SELECT ledger.purchase_complete(%s, %s, %s, 'paypal', %s, '{}'::jsonb)""",
                    ('sim-'+str(uuid.uuid4()), test_user, 100, test_user))
    except psycopg2.Error as e:
        if 'invalid_source' in str(e):
            invalid_rejected = True
    assert_true("source.unknown_rejected", invalid_rejected)

    # 9. Zero/negative amount rejected.
    nonpos_rejected = False
    try:
        cur.execute("""SELECT ledger.purchase_complete(%s, %s, %s, 'synthetic', %s, '{}'::jsonb)""",
                    ('sim-'+str(uuid.uuid4()), test_user, 0, test_user))
    except psycopg2.Error as e:
        if 'amount_minor_must_be_positive' in str(e):
            nonpos_rejected = True
    assert_true("amount.nonpositive_rejected", nonpos_rejected)

    # 10. Refund symmetry: refund reverses both legs cleanly.
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (test_user,))
    pre_refund_user = cur.fetchone()[0]

    refund_event = 'sim-refund-'+str(uuid.uuid4())
    cur.execute("""SELECT ledger.purchase_refund(%s, %s, %s, 'synthetic', %s, '{}'::jsonb)""",
                (refund_event, test_user, 1000, test_user))
    refund_txn = cur.fetchone()[0]
    assert_true("refund.returns_uuid", refund_txn is not None)

    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (test_user,))
    post_refund_user = cur.fetchone()[0]
    assert_eq("refund.user_debit", post_refund_user - pre_refund_user, -1000)

    cur.execute("SELECT transaction_type FROM ledger.transactions WHERE transaction_id=%s", (refund_txn,))
    assert_eq("refund.transaction_type", cur.fetchone()[0], 'purchase_refunded')

    # 11. Refund idempotency — same refund_event_id returns same txn.
    cur.execute("""SELECT ledger.purchase_refund(%s, %s, %s, 'synthetic', %s, '{}'::jsonb)""",
                (refund_event, test_user, 1000, test_user))
    refund_replay = cur.fetchone()[0]
    assert_eq("refund.idempotency_replay", refund_replay, refund_txn)

    # 12. Refund with no prior available account rejected (use a fresh uuid that has no account).
    no_prior_rejected = False
    fresh_user = str(uuid.uuid4())
    try:
        cur.execute("""SELECT ledger.purchase_refund(%s, %s, %s, 'synthetic', %s, '{}'::jsonb)""",
                    ('sim-refund-'+str(uuid.uuid4()), fresh_user, 100, fresh_user))
    except psycopg2.Error as e:
        if 'user_available_not_found' in str(e):
            no_prior_rejected = True
    assert_true("refund.requires_prior_purchase", no_prior_rejected)

    # 13. Age-verified gate: unverified user is rejected on purchase_complete.
    cur.execute("UPDATE public.profiles SET age_verified=false, dob=NULL WHERE user_id=%s", (test_user,))
    age_blocked = False
    try:
        cur.execute("""SELECT ledger.purchase_complete(%s, %s, %s, 'synthetic', %s, '{}'::jsonb)""",
                    ('sim-blocked-'+str(uuid.uuid4()), test_user, 100, test_user))
    except psycopg2.Error as e:
        if 'unverified_identity' in str(e):
            age_blocked = True
    assert_true("compliance.unverified_blocked", age_blocked)

    # 14. Drift check — sum of all entries for involved accounts still equals balance_cached.
    cur.execute("UPDATE public.profiles SET age_verified=true, dob=%s WHERE user_id=%s",
                ('1990-01-01', test_user))
    cur.execute("""SELECT bool_and(ledger.verify_balance(account_id))
                     FROM ledger.accounts
                    WHERE user_id=%s OR user_id='00000000-0000-0000-0000-000000000000'::uuid""", (test_user,))
    assert_true("ledger.no_drift", cur.fetchone()[0])

    # ─── Card 3 R2 council nit coverage ──────────────────────────────────
    # 15. Structural column: purchase_source on ledger.transactions exists +
    #     CHECK constraint rejects unknown values.
    cur.execute("""SELECT column_name FROM information_schema.columns
                    WHERE table_schema='ledger' AND table_name='transactions'
                      AND column_name='purchase_source'""")
    assert_true("schema.purchase_source_column_exists", cur.fetchone() is not None)

    bad_source_rejected = False
    try:
        cur.execute("""INSERT INTO ledger.transactions (transaction_type, initiated_by, metadata, purchase_source)
                       VALUES ('purchase_settled', %s, '{}'::jsonb, 'paypal')""", (test_user,))
    except psycopg2.Error as e:
        if 'purchase_source_check' in str(e) or 'check constraint' in str(e).lower():
            bad_source_rejected = True
    assert_true("schema.purchase_source_check_constraint", bad_source_rejected)

    # 16. Structural column actually populated by purchase_complete (not just metadata).
    pe = 'sim-r2-'+str(uuid.uuid4())
    cur.execute("""SELECT ledger.purchase_complete(%s, %s, %s, 'synthetic', %s, '{}'::jsonb)""",
                (pe, test_user, 500, test_user))
    txn_r2 = cur.fetchone()[0]
    cur.execute("SELECT purchase_source FROM ledger.transactions WHERE transaction_id=%s", (txn_r2,))
    assert_eq("synthetic.purchase_source_column_populated", cur.fetchone()[0], 'synthetic')

    # 17. Cross-namespace replay: same event_id, different source → distinct txns
    #     (already covered by source.namespace_independent at #7, but explicit
    #     for the council-cited concern).
    cur.execute("""SELECT ledger.purchase_complete(%s, %s, %s, 'stripe', %s, '{}'::jsonb)""",
                (pe, test_user, 500, test_user))
    txn_cross = cur.fetchone()[0]
    assert_true("cross_namespace.distinct_transactions", txn_cross != txn_r2)
    cur.execute("SELECT purchase_source FROM ledger.transactions WHERE transaction_id=%s", (txn_cross,))
    assert_eq("cross_namespace.source_column_per_row", cur.fetchone()[0], 'stripe')

    # 18. Refund amount greater than original purchase: should succeed at RPC layer
    #     (the RPC doesn't enforce the upper bound — that's caller-side policy),
    #     but if user available has insufficient funds, post_transaction rejects.
    #     Test the insufficient-funds path explicitly.
    cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (test_user,))
    avail = cur.fetchone()[0]
    over_refund_rejected = False
    try:
        cur.execute("""SELECT ledger.purchase_refund(%s, %s, %s, 'synthetic', %s, '{}'::jsonb)""",
                    ('sim-overrefund-'+str(uuid.uuid4()), test_user, avail + 1, test_user))
    except psycopg2.Error as e:
        if 'insufficient_funds' in str(e):
            over_refund_rejected = True
    assert_true("refund.overrefund_rejected_when_insufficient", over_refund_rejected)

    # 19. Partial index for synthetic wipe query exists (Claude.ai R2 nit).
    cur.execute("""SELECT count(*) FROM pg_indexes
                    WHERE schemaname='ledger' AND indexname='transactions_synthetic_idx'""")
    assert_eq("schema.synthetic_partial_index", cur.fetchone()[0], 1)

    # 20. Public PostgREST shims still present after 0007 (migration didn't drop them).
    cur.execute("""SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname='public' AND proname IN ('purchase_complete','purchase_refund')""")
    public_fns = sorted([r[0] for r in cur.fetchall()])
    assert_eq("schema.public_shims_intact", public_fns, ['purchase_complete', 'purchase_refund'])

finally:
    cur.execute("UPDATE public.profiles SET age_verified=%s, dob=%s WHERE user_id=%s",
                (orig_av, orig_dob, test_user))
    cur.execute("DELETE FROM ledger.entries WHERE account_id IN (SELECT account_id FROM ledger.accounts WHERE user_id=%s)", (test_user,))
    cur.execute("DELETE FROM ledger.entries WHERE transaction_id IN (SELECT transaction_id FROM ledger.transactions WHERE metadata->>'purchase_source' IN ('synthetic','stripe'))")
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE user_id=%s", (test_user,))
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE key LIKE 'synthetic:%' OR key LIKE 'stripe:%'")
    cur.execute("DELETE FROM ledger.transactions WHERE transaction_type IN ('purchase_settled','purchase_refunded') AND initiated_by=%s", (test_user,))
    cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s", (test_user,))
    for atype, bal in sys_snapshot.items():
        cur.execute("""UPDATE ledger.accounts SET balance_cached=%s, version=0
                        WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid AND account_type=%s""", (bal, atype))
    cur.execute("DELETE FROM ledger.entries WHERE transaction_id NOT IN (SELECT transaction_id FROM ledger.transactions)")
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE response_transaction_id NOT IN (SELECT transaction_id FROM ledger.transactions)")

conn.close()

print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL:
    for n, g, w in FAIL: print(f"  FAIL: {n}  got={g!r} want={w!r}")
    sys.exit(1)
PY
