#!/usr/bin/env bash
set -euo pipefail

# Lint pipeline — installs tools and runs all validators.
# Called by the reusable lint workflow and usable locally.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/install-tools.sh"

require_config
cd "$INSTANCE_ROOT"

echo "=== LLM Wiki Lint Pipeline ==="
echo "Instance root: $INSTANCE_ROOT"

install_all_lint_tools
configure_path

# Ensure pip user bin is on PATH for this shell too
export PATH="$HOME/.local/bin:$PATH"

echo ""
echo "--- markdownlint ---"
markdownlint-cli2 "wiki/**/*.md" "index.md" "log.md"

echo ""
echo "--- mdlint-obsidian ---"
mdlint wiki/ --vault wiki/ --severity error --format json

echo ""
echo "--- remark frontmatter schema ---"
npx remark wiki/ --frail

echo ""
echo "--- unique filenames ---"
dups=$(find wiki/ -name "*.md" -exec basename {} \; | sort | uniq -d)
if [ -n "$dups" ]; then
    echo "::error::Duplicate filenames in wiki/: $dups"
    exit 1
fi
echo "OK"

echo ""
echo "--- raw/ immutability ---"
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
    changed=$(git diff --name-only origin/main...HEAD -- raw/)
    if [ -n "$changed" ]; then
        echo "::error::Files in raw/ must not be modified: $changed"
        exit 1
    fi
fi
echo "OK"

echo ""
echo "--- wiki health check ---"
python3 .llm-wiki/scripts/wiki-health.py wiki/

echo ""
echo "=== Lint Pipeline Complete ==="
