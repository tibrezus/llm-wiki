#!/usr/bin/env bash
set -euo pipefail

# Fast pre-commit check — runs only error-level wiki-health checks.
# Designed to complete in <2 seconds. Slow checks (bidirectional, stale, index)
# are left to CI.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$INSTANCE_ROOT/wiki.config.yml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Skipping wiki-health pre-commit (no wiki.config.yml)"
    exit 0
fi

cd "$INSTANCE_ROOT"

python3 "$SCRIPT_DIR/wiki-health.py" wiki/ --errors-only
