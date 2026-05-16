#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$INSTANCE_ROOT/wiki.config.yml"

echo "=== QMD Setup ==="

if ! command -v qmd &>/dev/null; then
    echo "ERROR: qmd is not installed."
    echo "Install with: npm install -g @tobilu/qmd"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: wiki.config.yml not found at $CONFIG_FILE"
    echo "Run .llm-wiki/scripts/bootstrap.sh first."
    exit 1
fi

read_config() {
    python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    config = yaml.safe_load(f)
keys = sys.argv[2].split('.')
val = config
for k in keys:
    val = val[k]
print(val)
" "$CONFIG_FILE" "$1"
}

PROJECT_TITLE=$(read_config project.title)
GLOBAL_CONTEXT=$(read_config qmd.global_context)
ENTITY_CONTEXT=$(read_config qmd.entity_context)
CONCEPT_CONTEXT=$(read_config qmd.concept_context)
GUIDE_CONTEXT=$(read_config qmd.guide_context)
REFERENCE_CONTEXT=$(read_config qmd.reference_context)

echo "Creating wiki collection..."
qmd collection add "$INSTANCE_ROOT/wiki" --name wiki --mask "**/*.md" 2>/dev/null || \
    echo "Collection 'wiki' already exists."

echo "Setting global context..."
qmd context add / "$GLOBAL_CONTEXT" 2>/dev/null || true

echo "Setting directory contexts..."
qmd context add qmd://wiki/entities "$ENTITY_CONTEXT" 2>/dev/null || true
qmd context add qmd://wiki/concepts "$CONCEPT_CONTEXT" 2>/dev/null || true
qmd context add qmd://wiki/guides "$GUIDE_CONTEXT" 2>/dev/null || true
qmd context add qmd://wiki/reference "$REFERENCE_CONTEXT" 2>/dev/null || true

echo "Indexing wiki..."
qmd update

echo "Generating embeddings..."
qmd embed

echo "Checking index status..."
qmd status

echo ""
echo "=== QMD Setup Complete ==="
echo "Search: qmd query \"your question\""
echo "Status: qmd status"
