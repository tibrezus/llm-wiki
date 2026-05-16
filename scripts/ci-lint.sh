#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== LLM Wiki CI Lint Pipeline ==="
echo "Instance root: $INSTANCE_ROOT"

cd "$INSTANCE_ROOT"

echo "--- System Tools ---"
node --version
python3 --version
npm --version

echo "--- Bootstrap pip ---"
curl -sS https://bootstrap.pypa.io/get-pip.py | python3 - --break-system-packages

echo "--- Configure npm global bin ---"
echo "$(npm prefix -g)/bin" >> "$GITHUB_PATH"

echo "--- Install markdownlint-cli2 ---"
npm install -g markdownlint-cli2

echo "--- Markdown Lint ---"
markdownlint-cli2 "wiki/**/*.md" "index.md" "log.md"

echo "--- Install mdlint-obsidian ---"
python3 -m pip install --break-system-packages mdlint-obsidian

echo "--- Add pip user bin to PATH ---"
echo "$HOME/.local/bin" >> "$GITHUB_PATH"

echo "--- Obsidian Markdown Validation ---"
mdlint wiki/ --vault wiki/ --severity error --format json

echo "--- Install remark tools ---"
npm ci

echo "--- Frontmatter Schema Validation ---"
npx remark wiki/ --frail

echo "--- Install wiki-health dependencies ---"
python3 -m pip install --break-system-packages pyyaml

echo "--- Unique Filenames Check ---"
dups=$(find wiki/ -name "*.md" -exec basename {} \; | sort | uniq -d)
if [ -n "$dups" ]; then
    echo "::error::Duplicate filenames in wiki/: $dups"
    exit 1
fi

echo "--- Raw/ Immutability Check ---"
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
    changed=$(git diff --name-only origin/main...HEAD -- raw/)
    if [ -n "$changed" ]; then
        echo "::error::Files in raw/ must not be modified: $changed"
        exit 1
    fi
fi

echo "--- Wiki Health Check ---"
python3 .llm-wiki/scripts/wiki-health.py wiki/

echo ""
echo "=== Lint Pipeline Complete ==="
