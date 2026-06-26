#!/usr/bin/env bash
set -euo pipefail

# Architecture graph pipeline orchestrator.
#
# For every project declared under `arch.projects` in wiki.config.yml, acquire
# a SCIP code graph and roll it up, writing both into raw/arch/<name>.*:
#
#   graph: extract (default)  -> wiki CI clones the repo + runs the indexer
#   graph: {source: fetch}    -> wiki CI fetches a project-provided .scip URL
#
# In both modes the rollup (<name>.map.txt) is produced here from the .scip,
# because token budgeting is a wiki concern. Artifacts are the single source of
# truth for the LLM-authored architecture pages/D2 figures; committed to raw/.
#
# Run locally or in CI. Git commit/push of changed artifacts is handled by the
# reusable .github/workflows/arch.yml.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # .../scripts/arch
ARCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"             # .../scripts
MODULE_DIR="$(cd "$ARCH_DIR/.." && pwd)"             # the .llm-wiki submodule
LIB_DIR="$ARCH_DIR/lib"

source "$LIB_DIR/config.sh"
source "$LIB_DIR/install-tools.sh"
require_config
cd "$INSTANCE_ROOT"

RAW_ARCH="$INSTANCE_ROOT/raw/arch"
mkdir -p "$RAW_ARCH"

BUDGET=$(read_config_default arch.budget_tokens "8000")
PROJECT_COUNT=$(python3 - <<'PY'
import sys, yaml
with open("wiki.config.yml") as f:
    c = yaml.safe_load(f) or {}
ps = (c.get("arch") or {}).get("projects") or []
print(len(ps))
PY
)

if [ "$PROJECT_COUNT" -eq 0 ]; then
    echo "No arch.projects configured — nothing to do."
    exit 0
fi

# Ensure tooling: protobuf + protoc runtime for the rollup.
if ! python3 -c 'import google.protobuf' 2>/dev/null; then
    echo "Installing protobuf..."
    pip3 install --user protobuf 2>/dev/null \
        || pip3 install --break-system-packages protobuf 2>/dev/null \
        || { echo "::error::Could not install protobuf"; exit 1; }
fi
export PATH="$HOME/.local/bin:$PATH"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Iterate projects from config, robustly (values may be empty / contain spaces).
# Fields (US-separated, ASCII unit separator 0x1f so empty fields survive):
#   NAME REPO REF LANG INDEXER SUBPATH MODE SCIP_URL MAP_URL
while IFS=$'\x1f' read -r NAME REPO REF LANG INDEXER SUBPATH MODE SCIP_URL MAP_URL; do
    [ -n "$NAME" ] || continue
    OUT_SCIP="$RAW_ARCH/$NAME.scip"
    OUT_MAP="$RAW_ARCH/$NAME.map.txt"

    echo ""
    echo "=== Project: $NAME (mode=$MODE, lang=$LANG) ==="

    if [ "$MODE" = "fetch" ]; then
        # Project-owned generation: fetch the .scip the project publishes.
        [ -n "$SCIP_URL" ] || { echo "::error::$NAME: graph.scip_url is required"; exit 1; }
        echo "fetching .scip from $SCIP_URL"
        curl -fsSL "$SCIP_URL" -o "$OUT_SCIP"
        if [ -n "$MAP_URL" ]; then
            echo "fetching pre-rolled map.txt from $MAP_URL"
            curl -fsSL "$MAP_URL" -o "$OUT_MAP"
        else
            python3 "$SCRIPT_DIR/rollup.py" "$OUT_SCIP" -o "$OUT_MAP" -n "$NAME" -b "$BUDGET"
        fi
    else
        # Wiki-owned generation: clone + index.
        [ -n "$REPO" ] || { echo "::error::$NAME: repo is required for graph: extract"; exit 1; }
        echo "cloning $REPO@$REF and indexing"
        SRC="$TMP/$NAME"
        mkdir -p "$SRC"
        git clone --depth 1 --branch "$REF" "$REPO" "$SRC"
        INDEX_ROOT="$SRC"
        if [ -n "$SUBPATH" ]; then
            INDEX_ROOT="$SRC/$SUBPATH"
            [ -d "$INDEX_ROOT" ] || { echo "::error::arch path not found: $SUBPATH"; exit 1; }
        fi
        bash "$SCRIPT_DIR/extract.sh" "$INDEX_ROOT" "$LANG" "${INDEXER:-}" "$OUT_SCIP"
        python3 "$SCRIPT_DIR/rollup.py" "$OUT_SCIP" -o "$OUT_MAP" -n "$NAME" -b "$BUDGET"
    fi

    [ -s "$OUT_SCIP" ] || { echo "::error::$NAME: .scip missing/empty"; exit 1; }
    echo "wrote $OUT_SCIP ($(wc -c < "$OUT_SCIP") bytes) and $OUT_MAP"
done < <(python3 - <<'PY'
import yaml
with open("wiki.config.yml") as f:
    c = yaml.safe_load(f) or {}
for p in (c.get("arch") or {}).get("projects") or []:
    g = p.get("graph", "extract")
    if isinstance(g, dict):
        mode = g.get("source", "extract")
        scip_url = g.get("scip_url", "")
        map_url = g.get("map_url", "")
    else:
        mode, scip_url, map_url = "extract", "", ""
    print("\x1f".join([
        p.get("name", ""),
        p.get("repo", ""),
        p.get("ref", "main"),
        p.get("language", ""),
        p.get("indexer", ""),
        p.get("path", ""),
        mode, scip_url, map_url,
    ]))
PY
)

echo ""
echo "=== Architecture pipeline complete ==="
echo "Artifacts in $RAW_ARCH/ — review the diffs, then commit (immutable raw/)."
