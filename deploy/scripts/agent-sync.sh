#!/usr/bin/env bash
set -euo pipefail

# agent-sync.sh — the LLM-driven documentation step, orchestrated by harmostes.
#
# Runs AFTER reconcile.sh pushes changed content. harmostes (github.com/tibrezus/
# harmostes) drives ONE warm pi RPC session: the agent does arch-sync/update
# (read RIG/sources → update model/mermaid/pages → COMMIT, no push), harmostes
# runs gate-lint.sh (the full LOCAL lint pipeline — the same one remote CI runs),
# and on failure feeds the lint errors back to the SAME session up to MAX_FIXES.
# Only a green gate is pushed.
#
# This replaces the old `pi --print` + remote-CI-polling (ci-monitor.sh) loop:
#   - validation is now a local, in-process gate (no remote CI round-trip)
#   - feedback is a warm-session continuation (the agent keeps context)
#   - every tool call is observable (harmostes logs tool_execution events)
#   - a tool allowlist (read/bash/edit/grep) scopes the agent
#
# Usage: agent-sync.sh <wiki-dir> <project-name> [workflow] [dst-branch]
# Env:   LLM_WIKI_ZAI_TOKEN — ZAI API key
#        HARMOSTES — harmostes binary (default: harmostes, fallback /usr/local/bin/harmostes.py)
#        AGENT_FIX_RETRIES — max gate-feedback attempts (default 3)
#        AGENT_TIMEOUT — per-turn timeout seconds (default 1800)

WIKI_DIR="${1:?Usage: agent-sync.sh <wiki-dir> <project> [workflow] [dst-branch]}"
PROJECT="${2:?Usage: agent-sync.sh <wiki-dir> <project> [workflow] [dst-branch]}"
WORKFLOW="${3:-lc4}"
DST_BRANCH="${4:-main}"
MAX_FIXES="${AGENT_FIX_RETRIES:-3}"
TIMEOUT="${AGENT_TIMEOUT:-1800}"

log() { echo "[agent-sync] $(date -u +%H:%M:%S) $*"; }

[ -d "$WIKI_DIR" ] || { log "ERROR: wiki dir $WIKI_DIR not found"; exit 1; }

if [ -n "${LLM_WIKI_ZAI_TOKEN:-}" ]; then
    export ZAI_API_KEY="$LLM_WIKI_ZAI_TOKEN"
    MODEL="zai/glm-5.2"
    log "model: $MODEL | workflow: $WORKFLOW | project: $PROJECT"
else
    log "WARN: LLM_WIKI_ZAI_TOKEN not set — skipping agent step"
    exit 0
fi

command -v pi >/dev/null 2>&1 || { log "ERROR: pi not found on PATH"; exit 1; }
# Resolve the harmostes binary into an ARRAY so a "python3 /path/harmostes.py"
# value word-splits correctly. (A quoted scalar would be treated as one command
# name including the space → exit 127.) Honors $HARMOSTES, else 'harmostes' on
# PATH, else the baked-in /usr/local/bin/harmostes.py.
if [ -n "${HARMOSTES:-}" ]; then
    read -ra HARMOSTES_CMD <<<"$HARMOSTES"
elif command -v harmostes >/dev/null 2>&1; then
    HARMOSTES_CMD=(harmostes)
elif [ -x /usr/local/bin/harmostes.py ]; then
    HARMOSTES_CMD=(python3 /usr/local/bin/harmostes.py)
else
    log "ERROR: harmostes not found (tried \${HARMOSTES:-<unset>}, harmostes, /usr/local/bin/harmostes.py)"; exit 1
fi

# ── Build the task prompt ────────────────────────────────────────────────────
if [ "$WORKFLOW" = "lc4" ]; then
    [ -f "$WIKI_DIR/raw/arch/$PROJECT/rig.json" ] || {
        log "ERROR: no RIG for $PROJECT at raw/arch/$PROJECT/rig.json"; exit 1
    }
    cat > "/tmp/agent-sync-${PROJECT}-task.txt" <<PROMPT
You are working in the wiki repository at $WIKI_DIR.

The RIG for '$PROJECT' at raw/arch/$PROJECT/rig.json has just been updated by the
RIG controller (a deterministic build-system analysis tool).

Your task: keep the architecture documentation current.

CRITICAL: You MUST actually read the RIG file before making any decisions. Do NOT
assume the content based on previous runs. Read it fresh every time.

1. Read AGENTS.md for the wiki schema and the LC4 workflow.
2. Read the skill at /skills/wiki/SKILL.md — specifically the 'arch-sync' command.
3. Read the updated RIG: cat raw/arch/$PROJECT/rig.json
   Count the components yourself. The RIG may have changed significantly.
4. Read the current LikeC4 model (if it exists): cat raw/arch/$PROJECT/model.c4
5. Compare the RIG with the model. Identify what components were:
   - ADDED (in RIG but not in model)
   - DEPRECATED (in model but not in RIG)
   - CHANGED (modified dependencies, renamed, type changed)
   If the RIG component count differs from the model, the model MUST be updated.
   Do NOT report 'no changes' unless you have verified every component by name.
6. Update the LikeC4 model to reflect the RIG. Every element MUST correspond to a
   real entry in the RIG. Follow the RIG → C4 mapping:
   a. Context view: one softwareSystem + external_packages as externalSystem nodes.
      Group related packages (e.g., all docker/* → 'Docker Engine').
   b. Container view: executables → containers. Group libraries by function
      (api/, state/, tf/ patterns). Draw depends_on_ids between containers.
   c. Component views (one per container): each RIG component → component node.
      Write SYNTHESIZED descriptions using the component's name, source paths, and
      dependency pattern — NOT verbatim RIG quotes.
      Include the RIG comp-N ID as a comment. Model external_packages_ids as edges
      to external systems. Annotate evidence (file:line refs) and test coverage.
   d. Generate views: context, containers, one component view per major container.
7. Run: likec4 format raw/arch/$PROJECT/
8. Run: likec4 gen mermaid -o /tmp/mermaid raw/arch/$PROJECT/
9. Update wiki pages that embed architecture diagrams for $PROJECT.
   CRITICAL: Read the existing wiki page FIRST (cat wiki/entities/$PROJECT.md).
   Preserve ALL manually-written sections — only replace the architecture diagram
   section (Mermaid blocks generated from LikeC4). Keep human-added deployment
   notes, configuration examples, manual insights. Only the
   '## Architecture (C4D2 — RIG + LikeC4)' section + embedded Mermaid change.
10. Update index.md and append to log.md with operation 'arch-sync'.
    Include the actual component count in the log entry.
11. COMMIT your work:
        git add -A && git commit -m 'docs(arch-sync): $PROJECT'
    Do NOT push — a local validation gate runs next; the push happens only once
    the gate is green. If the gate fails, you will be told the exact lint errors
    in THIS session: fix them, commit again, and the gate re-runs.

Do NOT write architecture from memory. Every component, dependency, and boundary
MUST come from the RIG. Do NOT skip steps. Read the RIG, compare, update.
PROMPT

elif [ "$WORKFLOW" = "generic" ]; then
    cat > "/tmp/agent-sync-${PROJECT}-task.txt" <<PROMPT
You are working in the wiki repository at $WIKI_DIR.

New raw source material for '$PROJECT' has been placed at raw/$PROJECT/ by the
controller.

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
8. Maintain cross-references: use [Markdown links](../type/page-name.md).
9. Update index.md and append to log.md with operation 'update'.
10. COMMIT your work:
        git add -A && git commit -m 'docs(update): $PROJECT'
    Do NOT push — a local validation gate runs next; the push happens only once
    the gate is green. If the gate fails, you will be told the exact lint errors
    in THIS session: fix them, commit again, and the gate re-runs.

Follow the wiki page format strictly (frontmatter, entity types, See Also).
Use [Markdown links](relative/path.md) for cross-references — NOT [[wikilinks]].
Links must be relative paths from the current file. Never modify files in raw/.
PROMPT

else
    log "ERROR: unknown workflow '$WORKFLOW'"
    exit 1
fi

# ── harmostes: agent task → gate-lint.sh → feedback-as-session-continuation ──
# harmostes drives ONE warm pi RPC session. The agent does the sync + commits;
# harmostes runs gate-lint.sh (submodule init + consistency + full lint); on
# failure it feeds the lint stderr back to the SAME session up to MAX_FIXES.
# Exit 0 = gate green; 1 = failed after N fixes; 2 = pi/gate error.
log "starting harmostes-orchestrated agent sync…"
set +e
"${HARMOSTES_CMD[@]}" task \
    --skill /skills/wiki/SKILL.md \
    --model "$MODEL" \
    --tools read,bash,edit,grep \
    --workdir "$WIKI_DIR" \
    --task-file "/tmp/agent-sync-${PROJECT}-task.txt" \
    --gate "bash /usr/local/bin/gate-lint.sh '$WIKI_DIR'" \
    --max-fixes "$MAX_FIXES" \
    --log "/tmp/agent-sync-${PROJECT}-events.jsonl" \
    --timeout "$TIMEOUT"
HARMOSTES_RC=$?
set -e

# ── Green gate → push + record state ─────────────────────────────────────────
cd "$WIKI_DIR"

if [ "$HARMOSTES_RC" -ne 0 ]; then
    log "agent step did not reach a green gate (harmostes exit $HARMOSTES_RC) — NOT pushing"
    if curl -sf http://localhost:3500/v1.0/healthz >/dev/null 2>&1; then
        curl -sf -X POST "http://localhost:3500/v1.0/state/${DAPR_STATE_STORE:-statestore}" \
            -H "Content-Type: application/json" \
            -d "[{\"key\":\"$PROJECT:agent_status\",\"value\":\"gate-failed\"},{\"key\":\"$PROJECT:ci_status\",\"value\":\"failed\"}]" \
            >/dev/null 2>&1 || true
    fi
    exit 0   # non-fatal — reconcile.sh continues to the next WikiMap
fi

log "gate GREEN — pushing $PROJECT"
# Rebase the agent's commits onto the latest origin/DST_BRANCH before pushing:
# the agent can run for several minutes, during which the wiki's branch may
# advance (another project's arch-sync, a manual edit). Replay on top to avoid
# a non-fast-forward rejection. The worktree is detached, so rebase creates a
# new detached HEAD at the rebased commits — fine for `push HEAD:refs/heads/…`.
git fetch origin "$DST_BRANCH" 2>/dev/null || true
if git rebase "origin/$DST_BRANCH" 2>/dev/null; then
    git push origin "HEAD:refs/heads/$DST_BRANCH" 2>&1 || log "WARN: push failed (non-fast-forward after rebase?)"
else
    git rebase --abort 2>/dev/null || true
    log "WARN: rebase onto origin/$DST_BRANCH conflicted — NOT pushing (concurrent wiki edit touched same files)"
fi

COMMIT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
if curl -sf http://localhost:3500/v1.0/healthz >/dev/null 2>&1; then
    curl -sf -X POST "http://localhost:3500/v1.0/state/${DAPR_STATE_STORE:-statestore}" \
        -H "Content-Type: application/json" \
        -d "[{\"key\":\"$PROJECT:agent_commit\",\"value\":\"$COMMIT_SHA\"},{\"key\":\"$PROJECT:agent_status\",\"value\":\"synced\"},{\"key\":\"$PROJECT:ci_status\",\"value\":\"green\"}]" \
        >/dev/null 2>&1 || true
    log "state saved (commit=$COMMIT_SHA, ci=green)"
fi

log "agent-sync complete for $PROJECT ($WORKFLOW)"
exit 0
