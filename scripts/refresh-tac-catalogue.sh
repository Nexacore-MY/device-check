#!/bin/bash
# Refresh the tac_catalogue from upstream.
#
#   bash scripts/refresh-tac-catalogue.sh
#
# Fetches the current MoazEb/tac-database snapshot, normalises it (scripts/tac_normalise.py),
# and writes paste-ready SQL chunks to scripts/tac-sql/.
#
# WHY CHUNKS AND NOT psql: the live demo project's DB password is not available to us, and the
# Supabase Studio CSV import chokes well below 250k rows. Pasting numbered chunks into the SQL
# editor is the path that actually works. If you ever do get a working connection string, the
# faster route is a single \copy — see docs/runbooks or schema-fix-16.sql.
#
# The chunks UPSERT (on conflict do update), so a refresh corrects rows whose model text
# changed upstream. Rows that DISAPPEAR upstream are left in place — deletion is deliberately
# not automated, because a row vanishing upstream is more likely a data regression than a
# real retraction, and a stale-but-correct model beats a sudden fallback to the range.
#
# Cadence: quarterly is enough. The failure mode is graceful — a phone whose TAC we don't have
# falls back to the screen-size range, it never shows something wrong. Measure how often that
# happens before deciding to refresh more often:
#
#   select tac_reason, count(*) from sessions
#   where imei_extracted is not null group by 1 order by 2 desc;
#
# A rising tac_not_found share on RECENT sessions is the signal to refresh.

set -euo pipefail

UPSTREAM="https://raw.githubusercontent.com/MoazEb/tac-database/main/tac_full.csv"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/.tac-work"
OUT="$HERE/tac-sql"
CHUNK=20000

mkdir -p "$WORK" "$OUT"
rm -f "$OUT"/tac_part*.sql

echo "Fetching $UPSTREAM"
curl -fsSL "$UPSTREAM" -o "$WORK/tac_full.csv"
echo "  $(wc -l < "$WORK/tac_full.csv" | tr -d ' ') source rows, $(du -h "$WORK/tac_full.csv" | cut -f1)"

echo "Normalising"
python3 "$HERE/tac_normalise.py" "$WORK/tac_full.csv" > "$WORK/tac_catalogue.csv"

echo "Generating SQL chunks"
python3 - "$WORK/tac_catalogue.csv" "$OUT" "$CHUNK" <<'PY'
import csv, os, sys
src, out, chunk = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = [r for r in csv.DictReader(open(src)) if r['model']]
esc = lambda s: s.replace("'", "''")
n = 0
for i in range(0, len(rows), chunk):
    n += 1
    part = rows[i:i + chunk]
    p = os.path.join(out, f'tac_part{n}.sql')
    with open(p, 'w') as f:
        f.write(f"-- part {n}/{-(-len(rows)//chunk)}: {len(part)} rows\n")
        f.write("insert into tac_catalogue (tac,brand,model) values\n")
        f.write(",\n".join(
            f"('{r['tac']}','{esc(r['brand'])}','{esc(r['model'])}')" for r in part))
        # Upsert, so a refresh corrects rows whose model text changed upstream.
        f.write("\non conflict (tac) do update set brand = excluded.brand, model = excluded.model;\n")
    print(f"  {os.path.basename(p)}  {os.path.getsize(p)/1024:.0f} KB  {len(part)} rows")
print(f"{len(rows)} model-bearing rows in {n} chunks")
PY

cat <<EOF

Next:
  1. Paste each $OUT/tac_part*.sql into the Supabase SQL editor, in order.
  2. Re-apply the placeholder cleanup (schema-fix-16 does this too, but the upsert
     above can reintroduce rows the last cleanup nulled):
       update tac_catalogue set model = null where model = brand || ' Unknown';
  3. Verify:
       select count(*) as total, count(model) as with_model from tac_catalogue;
EOF
