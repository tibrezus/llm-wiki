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
# raw/ holds curated source documents that must NEVER be modified once placed.
# The single exception is raw/arch/ — that subdirectory holds CI-fetched /
# agent-regenerated Repository Intelligence Graphs (RIG JSONs) used by the
# C4D2 architecture workflow. RIGs are intentionally refreshed over time, so
# they are exempt from the immutability rule.
#
# This check only runs on pull/merge requests. PR/MR checkouts (actions/
# checkout, Forgejo Actions, GitLab CI) fetch only the PR ref by default and
# leave the base branch absent, which would make `git diff origin/main...HEAD`
# fail with 'bad revision'. We therefore resolve the base branch name from
# platform-specific env vars and fetch it explicitly before diffing.

base_ref=""
# GitHub Actions + Forgejo Actions (Gitea) — pull_request events
if [ -z "$base_ref" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
    base_ref="$GITHUB_BASE_REF"
fi
# GitLab CI — merge_request_event
if [ -z "$base_ref" ] && [ -n "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}" ]; then
    base_ref="$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
fi
# Bitbucket Pipelines / generic fallbacks
if [ -z "$base_ref" ] && [ -n "${BITBUCKET_PR_DESTINATION_BRANCH:-}" ]; then
    base_ref="$BITBUCKET_PR_DESTINATION_BRANCH"
fi

if [ -n "$base_ref" ]; then
    # Make the base branch locally resolvable (shallow-checkout safe). Best
    # effort: if the fetch fails (offline runner, restricted refspec, etc.) we
    # fall through to the rev-parse guard rather than failing the pipeline.
    git fetch --depth=1 origin "$base_ref" >/dev/null 2>&1 || true
    base="origin/$base_ref"
    if git rev-parse --verify --quiet "$base" >/dev/null; then
        # Changed raw/ files, EXCLUDING raw/arch/ (legitimate RIG additions).
        changed=$(git diff --name-only "${base}...HEAD" -- raw/ | grep -vE '^raw/arch/' || true)
        if [ -n "$changed" ]; then
            echo "::error::Files in raw/ (outside raw/arch/) must not be modified: $changed"
            exit 1
        fi
    else
        echo "::warning::raw/ immutability check skipped: base ref '$base' not resolvable"
    fi
fi
echo "OK"

echo ""
echo "--- wiki health check ---"
python3 .llm-wiki/scripts/wiki-health.py wiki/

echo ""
echo "=== Lint Pipeline Complete ==="
