#!/usr/bin/env bash
set -euo pipefail

# gate-lint.sh — the LLM agent's LOCAL validation gate (run by harmostes).
#
# harmostes runs this after the agent (arch-sync/update) edits the wiki. It is
# the SAME pipeline the wiki's remote CI runs, evaluated in-pod — so a green
# gate means the eventual push will pass CI, with no remote round-trip. On
# failure, harmostes feeds this script's stderr back to the agent's warm session.
#
# Steps:
#   1. init the .llm-wiki submodule (consistency compares against it; lint runs
#      .llm-wiki/scripts/* and resolves schema files from it)
#   2. ci-consistency.sh — drift check (generated files vs submodule). Fails →
#      the agent's feedback tells it to run bootstrap.sh and re-commit.
#   3. ci-lint.sh — the full pipeline: markdownlint, mdlint-obsidian, remark
#      frontmatter schema, mermaid render-check, likec4 format, unique
#      filenames, raw/ immutability, wiki-health, RIG compliance.
#
# The lint tools are baked into the controller image (markdownlint-cli2, mdlint,
# mmdc+Chromium, remark deps via npm install); ci-lint.sh's install_all_lint_tools
# is idempotent and skips them. The per-wiki remark deps (.remarkrc.mjs ESM
# imports) are resolved by `npm install` in the wiki dir (install_remark_deps).
#
# Usage: gate-lint.sh <wiki-dir>
# Exit: 0 = green; non-zero = validation failed (stderr = the concrete errors).

WIKI_DIR="${1:?Usage: gate-lint.sh <wiki-dir>}"
[ -d "$WIKI_DIR" ] || { echo "ERROR: wiki dir not found: $WIKI_DIR" >&2; exit 2; }

cd "$WIKI_DIR"

echo "=== gate: init submodule ==="
git submodule update --init --recursive >/dev/null 2>&1 || {
    echo "ERROR: could not init .llm-wiki submodule (network? detached worktree?)" >&2
    exit 2
}

echo "=== gate: consistency (generated files vs submodule) ==="
bash .llm-wiki/scripts/ci-consistency.sh

echo "=== gate: lint pipeline (markdownlint + mdlint + remark + mermaid + likec4 + health + rig) ==="
export PATH="$HOME/.local/bin:$(npm prefix -g 2>/dev/null)/bin:$PATH"
bash .llm-wiki/scripts/ci-lint.sh

echo "=== gate: GREEN ==="
