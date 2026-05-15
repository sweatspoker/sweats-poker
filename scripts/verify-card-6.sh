#!/usr/bin/env bash
# Card 6 (players table + FK retrofit on ipo.offerings) verification.

set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .env.local ]]; then echo "ERROR: .env.local not found" >&2; exit 2; fi
DSN=$(grep '^SUPABASE_DB_URL=' .env.local | head -1 | cut -d= -f2-)
if [[ -z "$DSN" ]]; then echo "ERROR: SUPABASE_DB_URL not set" >&2; exit 2; fi
export SWEATS_DSN="$DSN"

python3 - <<'PY'
import os, sys, uuid, json, psycopg2
dsn=os.environ['SWEATS_DSN']
conn=psycopg2.connect(dsn); conn.autocommit=True; cur=conn.cursor()
PASS,FAIL=[],[]
def aeq(n,g,w):
    if g==w: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,g,w)); print(f"  FAIL {n}: got={g!r} want={w!r}")
def atrue(n,c,d=""):
    if c: PASS.append(n); print(f"  PASS {n}")
    else: FAIL.append((n,c,True)); print(f"  FAIL {n}: {d}")

print("=== Card 6 verification ===")

# 1. Schema invariants.
cur.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name='players'")
aeq("schema.players_exists", cur.fetchone()[0], 1)
cur.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='players' AND table_name='players'")
aeq("schema.players_players_table", cur.fetchone()[0], 1)

# 2. CHECK constraints.
cur.execute("SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid WHERE t.relname='players' AND c.conname='players_status_check'")
sc = cur.fetchone()[0]
atrue("schema.status_check_active", 'active' in sc)
atrue("schema.status_check_suspended", 'suspended' in sc)
atrue("schema.status_check_retired", 'retired' in sc)
atrue("schema.status_check_pending_review", 'pending_review' in sc)

# 3. RPCs present.
for fn in ('upsert_player','is_tradeable'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='players' AND p.proname=%s",(fn,))
    aeq(f"rpc.players_{fn}_exists", cur.fetchone()[0], 1)
for fn in ('list_active_players','get_player','players_upsert'):
    cur.execute("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=%s",(fn,))
    aeq(f"rpc.public_{fn}_exists", cur.fetchone()[0], 1)

# 4. FK exists on ipo.offerings.
cur.execute("""SELECT count(*) FROM information_schema.table_constraints
                WHERE table_schema='ipo' AND table_name='offerings'
                  AND constraint_type='FOREIGN KEY' AND constraint_name='offerings_player_fk'""")
aeq("fk.offerings_player_fk_present", cur.fetchone()[0], 1)

# 5. Indexes.
cur.execute("SELECT count(*) FROM pg_indexes WHERE schemaname='players' AND indexname='players_status_sport_idx'")
aeq("schema.status_sport_idx", cur.fetchone()[0], 1)

# 6. RLS enabled.
cur.execute("SELECT relrowsecurity FROM pg_class WHERE relname='players' AND relnamespace='players'::regnamespace")
atrue("rls.enabled", cur.fetchone()[0])

# 7. End-to-end smoke: upsert players, query, change status, check is_tradeable.
try:
    pid = 'CARD6-TEST-'+str(uuid.uuid4())[:8]
    cur.execute("""SELECT players.upsert_player(%s,%s,%s,%s,%s,%s,%s,%s,'{}'::jsonb)""",
                (pid, 'Test Player', 'poker', 'flop_specialist', 'WSOP', None, 'active', None))
    aeq("upsert.create_returns_pid", cur.fetchone()[0], pid)

    cur.execute("SELECT players.is_tradeable(%s)",(pid,))
    aeq("is_tradeable.active_true", cur.fetchone()[0], True)

    # Suspend and re-check.
    cur.execute("""SELECT players.upsert_player(%s,%s,%s,%s,%s,%s,%s,%s,'{}'::jsonb)""",
                (pid, 'Test Player', 'poker', 'flop_specialist', 'WSOP', None, 'suspended', None))
    cur.execute("SELECT players.is_tradeable(%s)",(pid,))
    aeq("is_tradeable.suspended_false", cur.fetchone()[0], False)

    # Audit row emitted (look for 'player_updated' rows for this player).
    cur.execute("""SELECT count(*) FROM audit.events
                    WHERE source='players' AND action_type IN ('player_created','player_updated')
                      AND metadata->>'player_id'=%s""",(pid,))
    atrue("audit.player_events_emitted", cur.fetchone()[0] >= 2)

    # Public list_active_players excludes suspended.
    cur.execute("SELECT count(*) FROM public.list_active_players('poker') WHERE player_id=%s",(pid,))
    aeq("public.list_active_excludes_suspended", cur.fetchone()[0], 0)

    # Reactivate.
    cur.execute("""SELECT players.upsert_player(%s,%s,%s,%s,%s,%s,%s,%s,'{}'::jsonb)""",
                (pid, 'Test Player', 'poker', 'flop_specialist', 'WSOP', None, 'active', None))
    cur.execute("SELECT count(*) FROM public.list_active_players('poker') WHERE player_id=%s",(pid,))
    aeq("public.list_active_includes_active", cur.fetchone()[0], 1)

    # get_player returns all fields.
    cur.execute("SELECT display_name, status FROM public.get_player(%s)",(pid,))
    row = cur.fetchone()
    aeq("get_player.display_name", row[0], 'Test Player')
    aeq("get_player.status_active", row[1], 'active')

    # FK enforcement: try to create an offering with a missing player_id.
    rejected = False
    try:
        cur.execute("""INSERT INTO ipo.offerings (player_id, player_display_name, total_shares, shares_remaining, price_per_share_minor, opens_at, closes_at)
                       VALUES ('NONEXISTENT-PLAYER-XYZ', 'Ghost', 1, 1, 1000, now(), now()+interval '1 hour')""")
    except psycopg2.Error as e:
        if 'foreign key' in str(e).lower() or 'offerings_player_fk' in str(e):
            rejected = True
    atrue("fk.missing_player_id_rejected", rejected)

    # 8. Empty player_id rejected by RPC.
    rejected = False
    try:
        cur.execute("""SELECT players.upsert_player('','Empty','poker',NULL,NULL,NULL,'active',NULL,'{}'::jsonb)""")
    except psycopg2.Error as e:
        if 'player_id_required' in str(e): rejected = True
    atrue("upsert.empty_pid_rejected", rejected)

    # 9. Invalid status rejected by CHECK.
    rejected = False
    try:
        cur.execute("""SELECT players.upsert_player(%s,'Test2','poker',NULL,NULL,NULL,'invalid_status',NULL,'{}'::jsonb)""",
                    ('CARD6-INVALID-'+str(uuid.uuid4())[:6],))
    except psycopg2.Error as e:
        if 'status_check' in str(e) or 'check constraint' in str(e).lower(): rejected = True
    atrue("upsert.invalid_status_rejected", rejected)

finally:
    cur.execute("DELETE FROM ipo.offerings WHERE player_id LIKE 'CARD6-TEST-%' OR player_id LIKE 'NONEXISTENT%'")
    cur.execute("DELETE FROM audit.events WHERE source='players' AND occurred_at > now() - interval '5 minutes'")
    cur.execute("DELETE FROM players.players WHERE player_id LIKE %s OR player_id LIKE %s", ('CARD6-TEST-%','CARD6-INVALID-%'))

conn.close()
print(f"\n=== Result: {len(PASS)} PASS / {len(FAIL)} FAIL ===")
if FAIL:
    for n,g,w in FAIL: print(f"  FAIL: {n}  got={g!r} want={w!r}")
    sys.exit(1)
PY
