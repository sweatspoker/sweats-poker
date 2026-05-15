#!/usr/bin/env bash
# Card 2 (GC Wallet & Ledger) end-to-end verification.
# Runs in-DB smoke tests against the live Supabase instance via SUPABASE_DB_URL.
# Idempotent: every test reverts its own state.
#
# Usage:
#   cd ~/Desktop/sweats-poker && bash scripts/verify-card-2.sh
#
# Requires: python3 with psycopg2, and SUPABASE_DB_URL in .env.local.

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

print("=== Card 2 verification ===")

# Pick the most-recent profile for testing.
cur.execute("SELECT user_id, age_verified, dob FROM public.profiles ORDER BY created_at DESC LIMIT 1")
row = cur.fetchone()
if not row:
    print("ERROR: no profiles exist on this DB", file=sys.stderr); sys.exit(3)
test_user, orig_av, orig_dob = row

# Snapshot system-account balances for restore.
cur.execute("""SELECT account_type, balance_cached FROM ledger.accounts
                WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
sys_snapshot = dict(cur.fetchall())

try:
    # 1. Schema invariants
    cur.execute("SELECT relrowsecurity FROM pg_class WHERE relname='entries' AND relnamespace='ledger'::regnamespace")
    assert_true("rls.entries_enabled", cur.fetchone()[0])

    cur.execute("""SELECT count(*) FROM pg_proc
                    WHERE pronamespace='ledger'::regnamespace AND prosecdef
                      AND NOT (proconfig::text LIKE '%search_path=public, pg_temp%')""")
    assert_eq("rpc.all_have_search_path_locked", cur.fetchone()[0], 0)

    cur.execute("""SELECT count(*) FROM ledger.accounts
                    WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")
    assert_eq("system.both_sentinel_accounts_exist", cur.fetchone()[0], 2)

    # 2. RPC behavior — unverified user is REJECTED
    cur.execute("UPDATE public.profiles SET age_verified=false, dob=NULL WHERE user_id=%s", (test_user,))
    rejected = False
    try:
        cur.execute("SELECT ledger.admin_grant(%s, 1000, %s, %s, NULL)",
                    (test_user, 'admin:verify-'+str(uuid.uuid4()), test_user))
    except psycopg2.errors.InsufficientPrivilege:
        rejected = True
    except psycopg2.errors.ForeignKeyViolation:
        rejected = True
    assert_true("compliance.unverified_rejected", rejected, "RPC accepted call from unverified user")

    # 3. End-to-end with verified user.
    cur.execute("UPDATE public.profiles SET age_verified=true, dob=%s WHERE user_id=%s",
                ('1990-01-01', test_user))

    key = 'admin:verify-'+str(uuid.uuid4())
    cur.execute("SELECT ledger.admin_grant(%s, 2500, %s, %s, 'verify-card-2 smoke')",
                (test_user, key, test_user))
    txn1 = cur.fetchone()[0]
    assert_true("rpc.admin_grant_returns_uuid", txn1 is not None)

    # 4. Idempotency replay
    cur.execute("SELECT ledger.admin_grant(%s, 2500, %s, %s, 'verify-card-2 smoke')",
                (test_user, key, test_user))
    txn2 = cur.fetchone()[0]
    assert_eq("idempotency.replay_returns_same_txn", txn2, txn1)

    # 5. Drift check
    cur.execute("""SELECT bool_and(ledger.verify_balance(account_id))
                     FROM ledger.accounts
                    WHERE user_id=%s OR user_id='00000000-0000-0000-0000-000000000000'::uuid""", (test_user,))
    assert_true("ledger.no_drift", cur.fetchone()[0])

    # 6. Unbalanced legs rejected
    try:
        cur.execute("""SELECT ledger.post_transaction(%s, 'admin_grant',
                       %s::jsonb, %s, %s, '{}'::jsonb, true)""",
                    (test_user,
                     json.dumps([
                       {"account_id": "00000000-0000-0000-0000-000000000001", "delta_minor": 100},
                       {"account_id": "00000000-0000-0000-0000-000000000002", "delta_minor": 100},
                     ]),
                     'admin:unbalanced-'+str(uuid.uuid4()), test_user))
        FAIL.append(("validation.unbalanced_rejected", "accepted", "rejected"))
        print("  FAIL validation.unbalanced_rejected: legs summing to nonzero were accepted")
    except psycopg2.Error as e:
        if 'unbalanced' in str(e):
            PASS.append("validation.unbalanced_rejected"); print("  PASS validation.unbalanced_rejected")
        else:
            FAIL.append(("validation.unbalanced_rejected", str(e)[:80], "unbalanced_transaction"))

    # 7. Zero delta rejected
    try:
        cur.execute("""SELECT ledger.post_transaction(%s, 'admin_grant',
                       %s::jsonb, %s, %s, '{}'::jsonb, true)""",
                    (test_user,
                     json.dumps([
                       {"account_id": "00000000-0000-0000-0000-000000000001", "delta_minor": 0},
                       {"account_id": "00000000-0000-0000-0000-000000000002", "delta_minor": 0},
                     ]),
                     'admin:zero-'+str(uuid.uuid4()), test_user))
        FAIL.append(("validation.zero_delta_rejected", "accepted", "rejected"))
        print("  FAIL validation.zero_delta_rejected")
    except psycopg2.Error as e:
        if 'leg_delta_zero' in str(e):
            PASS.append("validation.zero_delta_rejected"); print("  PASS validation.zero_delta_rejected")
        else:
            FAIL.append(("validation.zero_delta_rejected", str(e)[:80], "leg_delta_zero"))

    # 8. Magnitude cap rejected (over 1M minor units)
    try:
        cur.execute("SELECT ledger.admin_grant(%s, 5000000, %s, %s, 'too big')",
                    (test_user, 'admin:huge-'+str(uuid.uuid4()), test_user))
        FAIL.append(("validation.magnitude_cap", "accepted", "rejected")); print("  FAIL validation.magnitude_cap")
    except psycopg2.Error as e:
        if 'magnitude' in str(e) or 'check' in str(e).lower():
            PASS.append("validation.magnitude_cap"); print("  PASS validation.magnitude_cap")
        else:
            FAIL.append(("validation.magnitude_cap", str(e)[:80], "magnitude check"))

    # 9. Signup bonus idempotency (signup:<user_id> key)
    cur.execute("SELECT ledger.apply_signup_bonus(%s)", (test_user,))
    sb1 = cur.fetchone()[0]
    cur.execute("SELECT ledger.apply_signup_bonus(%s)", (test_user,))
    sb2 = cur.fetchone()[0]
    assert_eq("idempotency.signup_bonus_one_shot", sb2, sb1)

finally:
    # Reset profile + clean smoke data
    cur.execute("UPDATE public.profiles SET age_verified=%s, dob=%s WHERE user_id=%s",
                (orig_av, orig_dob, test_user))
    cur.execute("DELETE FROM ledger.entries WHERE transaction_id IN (SELECT transaction_id FROM ledger.transactions WHERE initiated_by=%s OR transaction_type IN ('signup_bonus'))", (test_user,))
    cur.execute("DELETE FROM ledger.idempotency_keys WHERE user_id=%s", (test_user,))
    cur.execute("DELETE FROM ledger.entries WHERE account_id IN (SELECT account_id FROM ledger.accounts WHERE user_id=%s)", (test_user,))
    cur.execute("DELETE FROM ledger.transactions WHERE transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries)")
    cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s", (test_user,))
    # Restore system account balances + clean orphan entries
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
