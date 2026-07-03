#!/usr/bin/env bash
set -euo pipefail

# ci-monitor.sh — polls CI status for a wiki repo commit.
#
# Detects the CI platform from the wiki repo URL and polls until the run
# completes. Returns one of:
#   success — CI passed
#   failed  — CI failed (caller should self-heal)
#   timeout — polling exceeded max wait (non-fatal)
#   skip    — no token for this platform (non-fatal)
#
# Usage: ci-monitor.sh <wiki-repo-url> <commit-sha> [max-wait-seconds]
#
# Environment:
#   LLM_WIKI_GITHUB_TOKEN   — GitHub PAT (for github.com wikis)
#   LLM_WIKI_CODEBERG_TOKEN — Codeberg/Forgejo OAuth token (for codeberg.org)
#   LLM_WIKI_RZC_TOKEN      — Forgejo token (for git.rezus.cloud)

WIKI_REPO="${1:?Usage: ci-monitor.sh <wiki-repo-url> <commit-sha> [max-wait]}"
COMMIT_SHA="${2:?Usage: ci-monitor.sh <wiki-repo-url> <commit-sha> [max-wait]}"
MAX_WAIT="${3:-300}"

log() { echo "[ci-monitor] $*" >&2; }

# Extract owner/repo from a git URL
# e.g. git@github.com:owner/repo.git → owner/repo
#      ssh://git@codeberg.org/owner/repo.git → owner/repo
extract_repo_path() {
    echo "$WIKI_REPO" | \
        sed 's|\.git$||; s|.*[:/]\([^/]*/[^/]*\)$|\1|'
}

# Detect platform and configure API access
PLATFORM=""
HOST=""
REPO_PATH=""
AUTH_HEADER=""
API_BASE=""

REPO_PATH=$(extract_repo_path)

if echo "$WIKI_REPO" | grep -q 'github.com'; then
    PLATFORM="github"
    HOST="api.github.com"
    TOKEN="${LLM_WIKI_GITHUB_TOKEN:-}"
    [ -z "$TOKEN" ] && { echo "skip"; exit 0; }
    API_BASE="https://$HOST/repos/$REPO_PATH"
    AUTH_HEADER="Authorization: token $TOKEN"

elif echo "$WIKI_REPO" | grep -q 'codeberg.org'; then
    PLATFORM="forgejo"
    HOST="codeberg.org"
    TOKEN="${LLM_WIKI_CODEBERG_TOKEN:-}"
    [ -z "$TOKEN" ] && { echo "skip"; exit 0; }
    API_BASE="https://$HOST/api/v1/repos/$REPO_PATH"
    AUTH_HEADER="Authorization: token $TOKEN"

elif echo "$WIKI_REPO" | grep -q 'rezus.cloud'; then
    PLATFORM="forgejo"
    HOST=$(echo "$WIKI_REPO" | sed 's|.*://||; s|/.*||; s|.*@||')
    TOKEN="${LLM_WIKI_RZC_TOKEN:-}"
    [ -z "$TOKEN" ] && { echo "skip"; exit 0; }
    API_BASE="https://$HOST/api/v1/repos/$REPO_PATH"
    AUTH_HEADER="Authorization: token $TOKEN"

else
    log "unknown platform for $WIKI_REPO"
    echo "skip"
    exit 0
fi

log "platform=$PLATFORM repo=$REPO_PATH sha=${COMMIT_SHA:0:12}"

# --- Polling function ---
#
# Returns: success | failed | pending
poll() {
    case "$PLATFORM" in
        github)
            curl -sf -H "$AUTH_HEADER" \
                "$API_BASE/actions/runs?head_sha=$COMMIT_SHA&per_page=5" | \
                python3 -c "
import json, sys
data = json.load(sys.stdin)
runs = [r for r in data.get('workflow_runs', [])
        if r['head_sha'].startswith('${COMMIT_SHA:0:12}')]
if not runs:
    print('pending'); sys.exit()
# Check if ALL runs for this SHA are completed
pending = [r for r in runs if r['status'] != 'completed']
if pending:
    print('pending'); sys.exit()
# Check if any failed
failed = [r for r in runs if r['conclusion'] not in ('success', 'skipped')]
if failed:
    print('failed'); sys.exit()
print('success')
"
            ;;
        forgejo)
            # Forgejo Actions API: list workflow runs for this SHA
            curl -sf -H "$AUTH_HEADER" \
                "$API_BASE/actions/runs?sha=$COMMIT_SHA" | \
                python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except:
    print('pending'); sys.exit()
runs = data.get('workflow_runs', [])
if not runs:
    # Try tasks endpoint as fallback
    print('pending'); sys.exit()
pending = [r for r in runs if r.get('status') != 'completed']
if pending:
    print('pending'); sys.exit()
failed = [r for r in runs if r.get('conclusion') not in ('success', 'skipped', None)]
if failed:
    print('failed'); sys.exit()
print('success')
"
            ;;
    esac
}

# --- Poll loop ---
START=$(date +%s)
while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    if [ $ELAPSED -gt "$MAX_WAIT" ]; then
        log "timeout after ${ELAPSED}s"
        echo "timeout"
        exit 0
    fi

    RESULT=$(poll 2>/dev/null || echo "pending")
    case "$RESULT" in
        success)
            log "CI green ✓"
            echo "success"
            exit 0
            ;;
        failed)
            log "CI failed ✗"
            echo "failed"
            exit 0
            ;;
        pending)
            sleep 15
            ;;
        *)
            sleep 15
            ;;
    esac
done
