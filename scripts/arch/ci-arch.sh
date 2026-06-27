#!/usr/bin/env bash
set -euo pipefail

# Architecture graph pipeline — fetch + validate RIG JSON.
#
# For every project declared under `arch.projects` in wiki.config.yml:
#   1. fetch the project-published RIG JSON from its rig_url
#   2. validate it against schemas/repo-map.schema.yaml
#   3. write it verbatim to raw/arch/<name>.rig.json
#
# The RIG JSON is the single source of truth for the LLM-authored C4D2
# diagrams. It is committed to raw/ (immutable). No transformation, no
# rollup, no extraction — the project owns graph generation entirely.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # .../scripts/arch
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"           # .../scripts
LIB_DIR="$SCRIPTS_DIR/lib"

source "$LIB_DIR/config.sh"
require_config
cd "$INSTANCE_ROOT"

RAW_ARCH="$INSTANCE_ROOT/raw/arch"
mkdir -p "$RAW_ARCH"

# Check if any projects are declared.
PROJECT_COUNT=$(python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f) or {}
print(len((c.get('arch') or {}).get('projects') or []))
")

if [ "$PROJECT_COUNT" -eq 0 ]; then
    echo "No arch.projects configured — nothing to do."
    exit 0
fi

FAILED=0

# Iterate projects (unit-separator delimited so empty fields survive).
while IFS=$'\x1f' read -r NAME RIG_URL; do
    [ -n "$NAME" ] || continue
    echo ""
    echo "=== Project: $NAME ==="
    OUT="$RAW_ARCH/$NAME.rig.json"

    [ -n "$RIG_URL" ] || { echo "::error::$NAME: rig_url is required"; FAILED=1; continue; }

    echo "fetching RIG from $RIG_URL"
    if ! curl -fsSL "$RIG_URL" -o "$OUT"; then
        echo "::error::$NAME: failed to fetch RIG from $RIG_URL"
        FAILED=1
        continue
    fi

    [ -s "$OUT" ] || { echo "::error::$NAME: RIG is empty"; FAILED=1; continue; }

    echo "validating RIG..."
    if ! python3 "$SCRIPT_DIR/validate-rig.py" "$OUT"; then
        echo "::error::$NAME: RIG validation failed"
        FAILED=1
        continue
    fi

    echo "OK: $OUT ($(wc -c < "$OUT") bytes)"
done < <(python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f) or {}
for p in (c.get('arch') or {}).get('projects') or []:
    print('\x1f'.join([p.get('name',''), p.get('rig_url','')]))
")

echo ""
if [ "$FAILED" -eq 1 ]; then
    echo "=== Architecture pipeline FAILED ==="
    exit 1
fi
echo "=== Architecture pipeline complete ==="
echo "Artifacts in $RAW_ARCH/ — committed to raw/ (immutable)."
