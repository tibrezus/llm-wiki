#!/usr/bin/env bash
set -euo pipefail

# Pre-commit check — runs all wiki-health checks (errors + warnings).
# Both errors and warnings block the commit.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$INSTANCE_ROOT/wiki.config.yml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Skipping wiki-health pre-commit (no wiki.config.yml)"
    exit 0
fi

cd "$INSTANCE_ROOT"

python3 "$SCRIPT_DIR/wiki-health.py" wiki/ --strict
