#!/usr/bin/env bash
set -euo pipefail

# agent-sync.sh — the LLM-driven documentation step.
#
# Runs AFTER reconcile.sh pushes a changed RIG. Uses the pi.dev harness with
# the llm-wiki skill to transform the deterministic RIG into wiki documentation:
#   - updates the LikeC4 model from the RIG
#   - regenerates Mermaid diagrams
#   - identifies added/deprecated/changed components
#   - updates wiki pages, index.md, log.md
#   - commits and pushes
#
# The LLM decides what changed and keeps the documentation current. This is
# the interpretive step that cannot be automated deterministically.
#
# Environment:
#   WIKI_DIR    — path to the cloned wiki repo
#   PROJECT     — project name (matches raw/arch/<project>/)
#   LLM_WIKI_ZAI_TOKEN — ZAI API key (injected from ExternalSecret)
#
# Called by reconcile.sh after a successful RIG push.

WIKI_DIR="${1:?Usage: agent-sync.sh <wiki-dir> <project-name>}"
PROJECT="${2:?Usage: agent-sync.sh <wiki-dir> <project-name>}"

log() { echo "[agent-sync] $(date -u +%H:%M:%S) $*"; }

[ -d "$WIKI_DIR" ] || { log "ERROR: wiki dir $WIKI_DIR not found"; exit 1; }
[ -f "$WIKI_DIR/raw/arch/$PROJECT/rig.json" ] || { log "ERROR: no RIG for $PROJECT"; exit 1; }

# Configure ZAI API if the token is available
if [ -n "${LLM_WIKI_ZAI_TOKEN:-}" ]; then
    export ZAI_API_KEY="$LLM_WIKI_ZAI_TOKEN"
    MODEL="zai/glm-5.2"
    log "using model: $MODEL"
else
    log "WARN: LLM_WIKI_ZAI_TOKEN not set — skipping agent step"
    exit 0
fi

# Check that pi is available
command -v pi >/dev/null 2>&1 || { log "ERROR: pi not found on PATH"; exit 1; }

# Check that likec4 is available (needed for gen mermaid)
command -v likec4 >/dev/null 2>&1 || { log "WARN: likec4 not found — model update only, no Mermaid"; }

log "starting agent sync for $PROJECT…"

# The prompt: the agent reads the RIG, runs arch-sync, updates everything.
# The pi harness runs non-interactively (--print) with the wiki skill loaded.
# The agent has full file access and can run commands (likec4, git, etc.).
PROMPT="You are working in the wiki repository at $WIKI_DIR.

The RIG for '$PROJECT' at raw/arch/$PROJECT/rig.json has just been updated by the RIG controller (a deterministic build-system analysis tool).

Your task: keep the architecture documentation current. Do the following:

1. Read AGENTS.md for the wiki schema and documentation workflows.
2. Read the skill at /skills/wiki/SKILL.md for the 'arch-sync' command.
3. Read the updated RIG: cat raw/arch/$PROJECT/rig.json
4. Read the current LikeC4 model (if it exists): cat raw/arch/$PROJECT/model.c4
5. Compare the RIG with the model. Identify what components were:
   - ADDED (in RIG but not in model)
   - DEPRECATED (in model but not in RIG)
   - CHANGED (modified dependencies, renamed, type changed)
6. Update the LikeC4 model (raw/arch/$PROJECT/model.c4) to reflect the RIG.
   Every element MUST correspond to a real entry in the RIG.
7. Run: likec4 format raw/arch/$PROJECT/ (to validate and format)
8. Run: likec4 gen mermaid -o /tmp/mermaid raw/arch/$PROJECT/
9. Update wiki pages that embed architecture diagrams for $PROJECT with the regenerated Mermaid.
10. Update index.md and append to log.md with operation 'arch-sync'.
11. Commit all changes with message: 'docs(arch-sync): $PROJECT — auto-synced from updated RIG'
12. Push to origin.

Do NOT write architecture from memory. Every component, dependency, and boundary MUST come from the RIG. If the RIG shows something unexpected, document what the RIG shows.

Be thorough but concise. Focus on what changed — don't rewrite unchanged sections."

cd "$WIKI_DIR"

# Run the agent non-interactively
# --print: non-interactive (process prompt and exit)
# --skill: load the llm-wiki skill
# --approve: trust the wiki files (no confirmation prompts)
# --model: use GLM-5.2 via ZAI
timeout 600 pi --print \
    --skill /skills/wiki/SKILL.md \
    --model "$MODEL" \
    --approve \
    --no-skills \
    "$PROMPT" 2>&1 || {
    log "ERROR: agent sync failed (exit $?)"
    exit 1
}

log "agent sync complete for $PROJECT ✓"
