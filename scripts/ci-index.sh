#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== LLM Wiki CI Index Pipeline ==="
echo "Instance root: $INSTANCE_ROOT"

cd "$INSTANCE_ROOT"

echo "--- System Tools ---"
node --version
npm --version

echo "--- Configure npm global bin ---"
echo "$(npm prefix -g)/bin" >> "$GITHUB_PATH"

echo "--- Install QMD ---"
npm install -g @tobilu/qmd

echo "--- Install Bun ---"
curl -fsSL https://bun.sh/install | bash
echo "$HOME/.bun/bin" >> "$GITHUB_PATH"

echo "--- QMD Setup ---"
bash .llm-wiki/scripts/qmd-setup.sh

echo "--- Re-index Wiki ---"
qmd update

echo "--- Generate Embeddings ---"
qmd embed

echo "--- Verify Index ---"
qmd status

echo "--- Test Search ---"
result=$(qmd search "test query" --json -n 1)
if [ "$result" = "[]" ] || [ -z "$result" ]; then
    echo "::error::QMD search returned no results for test query"
    exit 1
fi
echo "QMD search verification passed"

echo ""
echo "=== Index Pipeline Complete ==="
