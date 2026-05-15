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

print("=== Card 14 verification ===")

# Schema
cur.execute("SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name IN ('tier','welcome_bonus_granted','tier_upgraded_at')")
aeq("schema.profile_columns", len(cur.fetchall()), 3)

cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='profiles' AND c.conname='profiles_tier_check'")
atrue("schema.tier_check_constraint", "'free'" in cur.fetchone()[0])

cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_promote_tier_on_purchase'")
aeq("rpc._promote_tier_on_purchase", cur.fetchone()[0], 1)

cur.execute("SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='ledger' AND c.relname='entries' AND t.tgname='trg_promote_tier_on_purchase'")
aeq("trigger.promote_tier_on_purchase", cur.fetchone()[0], 1)

cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_my_wallet'")
aeq("rpc.get_my_wallet", cur.fetchone()[0], 1)

# --- Signup welcome bonus ---
new_user = str(uuid.uuid4())
cur.execute("INSERT INTO auth.users (id) VALUES (%s)", (new_user,))
cur.execute("SELECT tier, welcome_bonus_granted FROM public.profiles WHERE user_id=%s", (new_user,))
tier, bonus_flag = cur.fetchone()
aeq("signup.default_tier_free", tier, 'free')
atrue("signup.welcome_bonus_granted_flag", bonus_flag)
cur.execute("SELECT balance_cached FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (new_user,))
aeq("signup.welcome_bonus_credited", cur.fetchone()[0], 1000)

# --- Free user cannot bid in IPO ---
cur.execute("INSERT INTO players.players (player_id, display_name, sport, status) VALUES ('p_c14','Test C14','poker','active') ON CONFLICT (player_id) DO UPDATE SET status='active'")
cur.execute("""INSERT INTO ipo.offerings (player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, opens_at, closes_at)
 VALUES ('p_c14','Test C14', 10, 10, 100, now() - interval '1 minute', now() + interval '1 hour')
 RETURNING offering_id""")
oid = cur.fetchone()[0]

def _free_bid():
    cur.execute("SELECT ipo.place_bid(%s, %s, 1, 100, %s, NULL)", (new_user, oid, f"c14_freebid_{uuid.uuid4()}"))
araises("gate.free_tier_cannot_bid_ipo", _free_bid, 'tier_upgraded_required_for_ipo')

# --- Free user cannot redeem ---
cur.execute("UPDATE public.profiles SET age_verified=true, dob='1990-01-01' WHERE user_id=%s", (new_user,))
cur.execute("SELECT redemptions.upsert_catalog_item(NULL, 'C14 Test Item', NULL, 500, 500, NULL, true, 1, %s)", (new_user,))
item_id = cur.fetchone()[0]
def _free_redeem():
    cur.execute("SELECT redemptions.request_catalog_item(%s, %s, %s, NULL)", (new_user, item_id, f"c14_freeredeem_{uuid.uuid4()}"))
araises("gate.free_tier_cannot_redeem", _free_redeem, 'tier_upgraded_required_for_redemption')

# --- Tier promotion on purchase_settled >= 10000 minor ---
# Use Card 3 purchase_complete (synthetic walkthrough).
cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ledger' AND p.proname='purchase_complete'")
if cur.fetchone()[0] > 0:
    cur.execute("SELECT ledger.purchase_complete(%s, %s, 10000, 'synthetic', %s, '{}'::jsonb)", (f"c14_purchase_{uuid.uuid4()}", new_user, new_user))
    cur.execute("SELECT tier, tier_upgraded_at IS NOT NULL FROM public.profiles WHERE user_id=%s", (new_user,))
    tier, stamped = cur.fetchone()
    aeq("upgrade.tier_after_purchase", tier, 'upgraded')
    atrue("upgrade.tier_upgraded_at_stamped", stamped)
else:
    # Fallback: synthesize the purchase_settled txn via post_transaction.
    cur.execute("SELECT account_id FROM ledger.accounts WHERE user_id=%s AND account_type='available'", (new_user,))
    user_avail = cur.fetchone()[0]
    cur.execute("SELECT account_id FROM ledger.accounts WHERE user_id='00000000-0000-0000-0000-000000000000' AND account_type='platform_treasury'")
    treasury = cur.fetchone()[0]
    import json
    legs = json.dumps([{"account_id": str(treasury), "delta_minor": -10000}, {"account_id": str(user_avail), "delta_minor": 10000}])
    cur.execute("SELECT ledger.post_transaction(%s, 'purchase_settled', %s::jsonb, %s, %s, %s::jsonb, false)", (new_user, legs, f"c14_purchase_{uuid.uuid4()}", new_user, '{}'))
    cur.execute("SELECT tier FROM public.profiles WHERE user_id=%s", (new_user,))
    aeq("upgrade.tier_after_purchase", cur.fetchone()[0], 'upgraded')

# --- Upgraded user CAN bid in IPO ---
cur.execute("SELECT ipo.place_bid(%s, %s, 1, 100, %s, NULL)", (new_user, oid, f"c14_upgradedbid_{uuid.uuid4()}"))
atrue("gate.upgraded_can_bid", cur.fetchone()[0] is not None)

# --- get_my_wallet returns the row when auth.uid() matches ---
# We can't easily set auth.uid() in a SQL session, but verify the function exists and works for service role lookup.
cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_my_wallet'")
aeq("read.get_my_wallet_exists", cur.fetchone()[0], 1)

# --- Drift ---
cur.execute("SELECT bool_and(ledger.verify_balance(account_id)) FROM ledger.accounts")
atrue("ledger.no_drift", cur.fetchone()[0])

# Cleanup (children before parents)
cur.execute("DELETE FROM ipo.bids WHERE offering_id IN (SELECT offering_id FROM ipo.offerings WHERE player_id='p_c14')")
cur.execute("DELETE FROM ipo.portfolio WHERE offering_id IN (SELECT offering_id FROM ipo.offerings WHERE player_id='p_c14')")
cur.execute("DELETE FROM ipo.offerings WHERE player_id='p_c14'")
cur.execute("DELETE FROM players.players WHERE player_id='p_c14'")
cur.execute("DELETE FROM redemptions.catalog WHERE catalog_item_id=%s", (item_id,))
cur.execute("DELETE FROM ledger.entries WHERE account_id IN (SELECT account_id FROM ledger.accounts WHERE user_id=%s)", (new_user,))
cur.execute("DELETE FROM ledger.idempotency_keys WHERE user_id=%s", (new_user,))
cur.execute("DELETE FROM ledger.accounts WHERE user_id=%s", (new_user,))
cur.execute("DELETE FROM public.profiles WHERE user_id=%s", (new_user,))
cur.execute("DELETE FROM auth.users WHERE id=%s", (new_user,))
cur.execute("DELETE FROM ledger.transactions WHERE transaction_id NOT IN (SELECT DISTINCT transaction_id FROM ledger.entries WHERE transaction_id IS NOT NULL)")
cur.execute("DELETE FROM audit.events WHERE source IN ('profiles','sessions','ipo','redemptions') AND occurred_at > now() - interval '10 minutes'")
cur.execute("""UPDATE ledger.accounts SET balance_cached = coalesce((SELECT sum(delta_minor) FROM ledger.entries WHERE account_id=ledger.accounts.account_id),0), version=version+1, updated_at=now() WHERE user_id='00000000-0000-0000-0000-000000000000'::uuid""")

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL: sys.exit(1)
PY
