#!/usr/bin/env bash
set -euo pipefail
changed=$(git diff --cached --name-only raw/)
if [ -n "$changed" ]; then
    echo "ERROR: never modify files in raw/: $changed"
    exit 1
fi
