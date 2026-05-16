#!/usr/bin/env bash
set -euo pipefail

# QMD search engine setup — reads wiki.config.yml for context strings.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/config.sh"

require_config

echo "=== QMD Setup ==="

if ! command -v qmd &>/dev/null; then
    echo "ERROR: qmd is not installed. Install with: npm install -g @tobilu/qmd"
    exit 1
fi

GLOBAL_CONTEXT=$(read_config qmd.global_context)
ENTITY_CONTEXT=$(read_config_default qmd.entity_context "")
CONCEPT_CONTEXT=$(read_config_default qmd.concept_context "")
GUIDE_CONTEXT=$(read_config_default qmd.guide_context "")
REFERENCE_CONTEXT=$(read_config_default qmd.reference_context "")

echo "Creating wiki collection..."
qmd collection add "$INSTANCE_ROOT/wiki" --name wiki --mask "**/*.md" 2>/dev/null || \
    echo "Collection 'wiki' already exists."

echo "Setting global context..."
qmd context add / "$GLOBAL_CONTEXT" 2>/dev/null || true

echo "Setting directory contexts..."
[ -n "$ENTITY_CONTEXT" ] && qmd context add qmd://wiki/entities "$ENTITY_CONTEXT" 2>/dev/null || true
[ -n "$CONCEPT_CONTEXT" ] && qmd context add qmd://wiki/concepts "$CONCEPT_CONTEXT" 2>/dev/null || true
[ -n "$GUIDE_CONTEXT" ] && qmd context add qmd://wiki/guides "$GUIDE_CONTEXT" 2>/dev/null || true
[ -n "$REFERENCE_CONTEXT" ] && qmd context add qmd://wiki/reference "$REFERENCE_CONTEXT" 2>/dev/null || true

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
