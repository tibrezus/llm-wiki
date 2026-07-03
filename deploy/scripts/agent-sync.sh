#!/usr/bin/env bash
set -euo pipefail

# agent-sync.sh — the LLM-driven documentation step.
#
# Runs AFTER reconcile.sh pushes changed content. Uses the pi.dev harness with
# the llm-wiki skill and GLM-5.2 (via ZAI) to transform deterministic inputs
# into wiki documentation.
#
# The workflow type determines what the LLM does:
#   lc4     — reads the updated RIG, updates the LikeC4 model + Mermaid diagrams
#   generic — reads new raw source material, creates/updates wiki pages
#
# After the agent pushes, a CI self-healing loop kicks in:
#   1. ci-monitor.sh polls the CI run triggered by the push
#   2. If CI fails, the agent is re-invoked with "run lint, fix errors, push"
#   3. Repeat up to MAX_CI_RETRIES times
#
# Usage: agent-sync.sh <wiki-dir> <project-name> [workflow]
#
# Environment:
#   LLM_WIKI_ZAI_TOKEN — ZAI API key (injected from ExternalSecret)
#   LLM_WIKI_GITHUB_TOKEN — GitHub PAT (for GitHub wiki CI monitoring)
#   LLM_WIKI_CODEBERG_TOKEN — Codeberg token (for Codeberg CI monitoring)

WIKI_DIR="${1:?Usage: agent-sync.sh <wiki-dir> <project-name> [workflow]}"
PROJECT="${2:?Usage: agent-sync.sh <wiki-dir> <project-name> [workflow]}"
WORKFLOW="${3:-lc4}"

# CI self-healing configuration
MAX_CI_RETRIES=3
CI_POLL_WAIT=300   # max seconds to wait for CI per attempt

log() { echo "[agent-sync] $(date -u +%H:%M:%S) $*"; }

[ -d "$WIKI_DIR" ] || { log "ERROR: wiki dir $WIKI_DIR not found"; exit 1; }

# Configure ZAI API
if [ -n "${LLM_WIKI_ZAI_TOKEN:-}" ]; then
    export ZAI_API_KEY="$LLM_WIKI_ZAI_TOKEN"
    MODEL="zai/glm-5.2"
    log "model: $MODEL | workflow: $WORKFLOW | project: $PROJECT"
else
    log "WARN: LLM_WIKI_ZAI_TOKEN not set — skipping agent step"
    exit 0
fi

command -v pi >/dev/null 2>&1 || { log "ERROR: pi not found on PATH"; exit 1; }

WIKI_REPO=$(cd "$WIKI_DIR" && git remote get-url origin 2>/dev/null || echo "")

# Build the prompt based on workflow type
if [ "$WORKFLOW" = "lc4" ]; then
    [ -f "$WIKI_DIR/raw/arch/$PROJECT/rig.json" ] || {
        log "ERROR: no RIG for $PROJECT at raw/arch/$PROJECT/rig.json"; exit 1
    }

    PROMPT="You are working in the wiki repository at $WIKI_DIR.

The RIG for '$PROJECT' at raw/arch/$PROJECT/rig.json has just been updated by the RIG controller (a deterministic build-system analysis tool).

Your task: keep the architecture documentation current.

1. Read AGENTS.md for the wiki schema and the LC4 workflow.
2. Read the skill at /skills/wiki/SKILL.md — specifically the 'arch-sync' command.
3. Read the updated RIG: cat raw/arch/$PROJECT/rig.json
4. Read the current LikeC4 model (if it exists): cat raw/arch/$PROJECT/model.c4
5. Compare the RIG with the model. Identify what components were:
   - ADDED (in RIG but not in model)
   - DEPRECATED (in model but not in RIG)
   - CHANGED (modified dependencies, renamed, type changed)
6. Update the LikeC4 model to reflect the RIG. Every element MUST correspond to a real entry in the RIG.
7. Run: likec4 format raw/arch/$PROJECT/
8. Run: likec4 gen mermaid -o /tmp/mermaid raw/arch/$PROJECT/
9. Update wiki pages that embed architecture diagrams for $PROJECT.
10. Update index.md and append to log.md with operation 'arch-sync'.
11. Commit: git add -A && git commit -m 'docs(arch-sync): $PROJECT'
12. Push: git push origin main

Do NOT write architecture from memory. Every component, dependency, and boundary MUST come from the RIG."

elif [ "$WORKFLOW" = "generic" ]; then
    PROMPT="You are working in the wiki repository at $WIKI_DIR.

New raw source material for '$PROJECT' has been placed at raw/$PROJECT/ by the controller.

Your task: keep the documentation current by processing the new sources.

1. Read AGENTS.md for the wiki schema and the Generic workflow.
2. Read the skill at /skills/wiki/SKILL.md — specifically the 'update' command.
3. Explore the source material: ls raw/$PROJECT/ and read the key files.
4. Compare with existing wiki pages. Identify what is:
   - NEW — topics in the sources not yet documented in the wiki
   - DEPRECATED — wiki pages describing features/behavior no longer in the sources
   - CHANGED — pages that need updating to match the current sources
5. Create new wiki pages for uncovered topics (correct entity-type directory).
6. Update existing pages with new or changed information.
7. Add Mermaid diagrams where they help (sequence, flowchart, etc.).
8. Maintain cross-references: add [[wikilinks]] from related pages.
9. Update index.md and append to log.md with operation 'update'.
10. Commit: git add -A && git commit -m 'docs(update): $PROJECT'
11. Push: git push origin main

Follow the wiki page format strictly (frontmatter, entity types, See Also).
Never modify files in raw/."

else
    log "ERROR: unknown workflow '$WORKFLOW'"
    exit 1
fi

cd "$WIKI_DIR"

# --- Phase 1: Run the agent (initial documentation update) ---
log "starting agent sync…"
timeout 1800 pi --print \
    --skill /skills/wiki/SKILL.md \
    --model "$MODEL" \
    --approve \
    --no-skills \
    "$PROMPT" 2>&1 || {
    log "ERROR: agent sync failed (exit $?)"
    exit 1
}

log "agent sync complete for $PROJECT ($WORKFLOW)"

# --- Phase 2: CI self-healing loop ---
#
# After the agent pushes, monitor the CI run it triggered. If CI fails,
# re-invoke the agent with instructions to run the lint pipeline locally,
# fix the errors, and push again. Repeat up to MAX_CI_RETRIES times.

if [ -z "$WIKI_REPO" ]; then
    log "no wiki repo URL — skipping CI monitoring"
    exit 0
fi

if [ ! -f /usr/local/bin/ci-monitor.sh ]; then
    log "ci-monitor.sh not found — skipping CI monitoring"
    exit 0
fi

COMMIT_SHA=$(git rev-parse HEAD)
log "post-push CI monitoring for ${COMMIT_SHA:0:12}…"

for attempt in $(seq 1 "$MAX_CI_RETRIES"); do
    log "CI monitoring attempt $attempt/$MAX_CI_RETRIES…"

    CI_STATUS=$(timeout $((CI_POLL_WAIT + 30)) \
        bash /usr/local/bin/ci-monitor.sh "$WIKI_REPO" "$COMMIT_SHA" "$CI_POLL_WAIT" 2>/dev/null \
        || echo "skip")

    case "$CI_STATUS" in
        success)
            log "CI green ✓ — pipeline complete"
            exit 0
            ;;
        skip)
            log "CI monitoring not available for this platform — skipping"
            exit 0
            ;;
        timeout)
            log "CI polling timed out — assuming OK (non-blocking)"
            exit 0
            ;;
        failed)
            log "CI FAILED (attempt $attempt) — invoking agent to fix…"

            FIX_PROMPT="You are working in the wiki repository at $WIKI_DIR.

Your previous commit (${COMMIT_SHA:0:12}) FAILED CI. The wiki CI pipeline checks:
  markdownlint, mdlint-obsidian, remark frontmatter schema,
  Mermaid render check, LikeC4 format check,
  unique filenames, raw/ immutability, and wiki health.

Find and fix every error:
1. Run the lint pipeline: bash .llm-wiki/scripts/ci-lint.sh
2. Read the error output carefully.
3. Fix every error in the relevant files.
4. Re-run the lint to confirm: bash .llm-wiki/scripts/ci-lint.sh
5. When all errors are fixed, commit and push:
   git add -A && git commit -m 'fix: resolve CI lint failures' && git push origin main

Do NOT modify files in raw/. Follow the wiki schema in AGENTS.md."

            timeout 1200 pi --print \
                --skill /skills/wiki/SKILL.md \
                --model "$MODEL" \
                --approve \
                --no-skills \
                "$FIX_PROMPT" 2>&1 || {
                log "WARN: agent fix attempt $attempt failed"
            }

            # Check if the agent actually made changes
            NEW_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
            if [ -z "$NEW_SHA" ] || [ "$NEW_SHA" = "$COMMIT_SHA" ]; then
                log "agent made no changes — stopping CI healing loop"
                exit 0
            fi
            COMMIT_SHA="$NEW_SHA"
            log "agent pushed fix commit ${COMMIT_SHA:0:12}"
            ;;
    esac
done

log "CI healing loop exhausted ($MAX_CI_RETRIES attempts) — CI may still be red"
exit 0
