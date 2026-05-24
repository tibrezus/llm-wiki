#!/usr/bin/env bash
set -euo pipefail
dups=$(find wiki/ -name "*.md" -exec basename {} \; | sort | uniq -d)
if [ -n "$dups" ]; then
    echo "ERROR: duplicate filenames in wiki/: $dups"
    exit 1
fi
