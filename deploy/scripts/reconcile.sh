#!/usr/bin/env bash
set -euo pipefail

# reconcile.sh — the controller's reconciliation loop.
#
# Runs inside the controller pod (KEDA ScaledJob or CronJob). For every
# WikiMap CR in the llm-wiki namespace:
#   1. resolve the source artifact (Flux GitRepository)
#   2. check Dapr state for fast skip (if revision already processed)
#   3. if changed: fetch cached wiki repo, run emitter, push RIG
#   4. run LLM agent step (arch-sync or update)
#   5. publish Dapr event (wiki.docs.updated)
#
# Caching layers (when enabled):
#   - JuiceFS PVC at $CACHE_DIR: git bare clones, Go modules, npm
#   - Dapr state store: last-processed revision, RIG hash, component count
#   - Dapr pub/sub: event notifications
#
# Environment:
#   NAMESPACE       — namespace to watch (default: llm-wiki)
#   EMITTERS_DIR    — emitter scripts (default: /emitters)
#   CACHE_DIR       — PVC cache directory (default: /cache)
#   DAPR_STATE_STORE — Dapr state component name (default: statestore)
#   DAPR_PUBSUB     — Dapr pub/sub component name (default: pubsub)

NAMESPACE="${NAMESPACE:-llm-wiki}"
EMITTERS_DIR="${EMITTERS_DIR:-/emitters}"
CACHE_DIR="${CACHE_DIR:-/cache}"
DAPR_STATE_STORE="${DAPR_STATE_STORE:-statestore}"
DAPR_PUBSUB="${DAPR_PUBSUB:-pubsub}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ── Dapr helpers ──────────────────────────────────────────────────
# All Dapr calls go through the sidecar at localhost:3500.
# If Dapr isn't injected, these are no-ops (graceful degradation).

DAPR_ENABLED=false
# Wait for Dapr sidecar to be ready (up to 30 seconds)
for _ in $(seq 1 15); do
    if curl -sf http://localhost:3500/v1.0/healthz >/dev/null 2>&1; then
        DAPR_ENABLED=true
        break
    fi
    sleep 2
done

dapr_save() {
    local key="$1" value="$2"
    $DAPR_ENABLED && curl -sf -X POST "http://localhost:3500/v1.0/state/${DAPR_STATE_STORE}" \
        -H "Content-Type: application/json" \
        -d "[{\"key\": \"$key\", \"value\": \"$value\"}]" >/dev/null 2>&1 || true
}

dapr_load() {
    if $DAPR_ENABLED; then
        curl -sf "http://localhost:3500/v1.0/state/${DAPR_STATE_STORE}/$1" 2>/dev/null | tr -d '"'
    fi
}

dapr_publish() {
    local topic="$1" data="$2"
    $DAPR_ENABLED && curl -sf -X POST "http://localhost:3500/v1.0/publish/${DAPR_PUBSUB}/${topic}" \
        -H "Content-Type: application/json" \
        -d "$data" >/dev/null 2>&1 || true
}

# ── Git cache helpers ─────────────────────────────────────────────
# Uses bare clones on the PVC. First run clones; subsequent runs
# fetch + worktree (sub-second vs 5-10s clone).

clone_or_fetch_wiki() {
    local url="$1" branch="$2" name="$3" dest="$4"
    local cache="$CACHE_DIR/repos/${name}-wiki"

    if [ -d "$cache" ]; then
        # Cached — fetch delta into local branch ref, then worktree
        log "  fetching wiki (cached)…"
        git -C "$cache" fetch origin "$branch:refs/heads/$branch" 2>&1 | tail -1 || true
        git -C "$cache" worktree remove -f "$dest" 2>/dev/null || true
        git -C "$cache" worktree add --detach "$dest" "$branch" 2>&1 | tail -1
    else
        # First run — bare clone (branches stored as local refs/heads/*), then worktree
        log "  cloning wiki (first run, caching)…"
        mkdir -p "$CACHE_DIR/repos"
        git clone --bare "$url" "$cache" 2>&1 | tail -1 || return 1
        git -C "$cache" worktree add --detach "$dest" "$branch" 2>&1 | tail -1
    fi
}

# ── Kubernetes helpers ────────────────────────────────────────────

get_wikimaps() {
    kubectl get wikimaps -n "$NAMESPACE" -o json 2>/dev/null || {
        log "ERROR: cannot list wikimaps in $NAMESPACE"
        return 1
    }
}

get_flux_artifact() {
    kubectl get gitrepository "$1" -n "$NAMESPACE" \
        -o jsonpath='{.status.artifact.url}{"\t"}{.status.artifact.revision}' 2>/dev/null
}

download_artifact() {
    curl -fsSL "$1" | tar -xzf - -C "$2"
}

patch_status() {
    local name="$1" key="$2" value="$3"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    kubectl patch wikimap "$name" -n "$NAMESPACE" --type=merge -p \
        "{\"status\":{\"${key}\":\"${value}\",\"lastRunAt\":\"${now}\"}}" \
        --subresource=status 2>/dev/null || \
    kubectl patch wikimap "$name" -n "$NAMESPACE" --type=merge -p \
        "{\"status\":{\"${key}\":\"${value}\",\"lastRunAt\":\"${now}\"}}" 2>/dev/null || \
    log "  WARN: could not patch status for $name"
}

# ── Main reconciliation loop ──────────────────────────────────────

# Ensure cache directories exist
mkdir -p "$CACHE_DIR/repos" "$CACHE_DIR/go" "$CACHE_DIR/npm" "$CACHE_DIR/pi" "$CACHE_DIR/rigs" 2>/dev/null || true

ITEMS_JSON="$(get_wikimaps)"
COUNT=$(echo "$ITEMS_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['items']))")

if [ "$COUNT" -eq 0 ]; then
    log "No WikiMap CRs found in $NAMESPACE — nothing to do."
    exit 0
fi

log "Reconciling $COUNT WikiMap(s)…"
$DAPR_ENABLED && log "Dapr: enabled (state=$DAPR_STATE_STORE, pubsub=$DAPR_PUBSUB)" || log "Dapr: not detected (running without cache/state)"

echo "$ITEMS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    name = item['metadata']['name']
    spec = item.get('spec', {})
    status = item.get('status', {})
    src = spec.get('source', {})
    dst = spec.get('destination', {})
    print('\t'.join([
        name,
        spec.get('workflow', 'lc4'),
        src.get('repo', ''),
        src.get('language', ''),
        src.get('branch', 'main'),
        dst.get('wikiRepo', ''),
        dst.get('wikiBranch', 'main'),
        dst.get('projectDir', ''),
        dst.get('deployKeySecret', 'llm-wiki-deploy-key'),
        status.get('lastProcessedRevision', ''),
    ]))
" | while IFS=$'\t' read -r NAME WORKFLOW SRC_REPO SRC_LANG SRC_BRANCH DST_WIKI DST_BRANCH DST_DIR DEPLOY_SECRET LAST_REV; do
    log "=== $NAME ==="
    log "  workflow: $WORKFLOW\n  source:   $SRC_REPO ($SRC_LANG)"

    # Resolve the source artifact
    ARTIFACT_URL=""
    ARTIFACT_REV=""
    if kubectl get gitrepository "$SRC_REPO" -n "$NAMESPACE" &>/dev/null; then
        ARTIFACT_DATA="$(get_flux_artifact "$SRC_REPO")" || true
        ARTIFACT_URL="$(echo "$ARTIFACT_DATA" | cut -f1)"
        ARTIFACT_REV="$(echo "$ARTIFACT_DATA" | cut -f2)"
    else
        log "  cloning $SRC_REPO (direct git URL)…"
        SRC_DIR="$WORKDIR/$NAME-src"
        git clone --depth 1 --branch "$SRC_BRANCH" "$SRC_REPO" "$SRC_DIR" 2>/dev/null || {
            log "  ERROR: cannot clone $SRC_REPO"
            patch_status "$NAME" "lastProcessedRevision" "FAILED: clone error"
            continue
        }
        ARTIFACT_REV="$(git -C "$SRC_DIR" rev-parse --short HEAD)"
        ARTIFACT_URL=""
    fi

    [ -n "$ARTIFACT_REV" ] || { log "  ERROR: cannot resolve revision for $SRC_REPO"; continue; }
    log "  revision: $ARTIFACT_REV"

    # ── Fast skip via Dapr state ──
    # If Dapr has this revision cached AND it matches the WikiMap status,
    # skip entirely — no clone, no emit, no agent.
    DAPR_REV=$(dapr_load "$NAME:processed_revision")
    if [ -n "$DAPR_REV" ] && [ "$DAPR_REV" = "$ARTIFACT_REV" ] && [ "$ARTIFACT_REV" = "$LAST_REV" ]; then
        log "  SKIP (Dapr cache: revision unchanged since last run)"
        continue
    fi

    # Also skip if WikiMap status matches (non-Dapr fallback)
    if [ "$ARTIFACT_REV" = "$LAST_REV" ]; then
        log "  SKIP (already processed)"
        continue
    fi

    # Prepare source directory
    SRC_DIR="$WORKDIR/$NAME-src"
    if [ -n "$ARTIFACT_URL" ]; then
        mkdir -p "$SRC_DIR"
        log "  downloading Flux artifact…"
        download_artifact "$ARTIFACT_URL" "$SRC_DIR" || {
            log "  ERROR: cannot download artifact"
            patch_status "$NAME" "lastProcessedRevision" "FAILED: artifact download"
            continue
        }
    fi

    # ── Workflow branching ──

    WIKI_DIR="$WORKDIR/$NAME-wiki"
    ARTIFACT_SHA=""

    # Clone or fetch wiki repo (uses PVC cache if available)
    WIKI_URL_AUTH="$DST_WIKI"
    if [ -n "${LLM_WIKI_GITHUB_TOKEN:-}" ] && echo "$DST_WIKI" | grep -q 'github.com'; then
        WIKI_URL_AUTH=$(echo "$DST_WIKI" | sed "s|https://github.com|https://x-access-token:${LLM_WIKI_GITHUB_TOKEN}@github.com|; s|git@github.com:|https://x-access-token:${LLM_WIKI_GITHUB_TOKEN}@github.com/|")
    fi
    if echo "$DST_WIKI" | grep -q '^ssh://'; then
        export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i /root/.ssh/id_ed25519"
    fi

    clone_or_fetch_wiki "$WIKI_URL_AUTH" "$DST_BRANCH" "$NAME" "$WIKI_DIR" || {
        log "  ERROR: cannot clone/fetch wiki repo"
        patch_status "$NAME" "lastProcessedRevision" "FAILED: wiki clone"
        continue
    }

    if [ "$WORKFLOW" = "lc4" ]; then
        # ── LC4: generate RIG ──

        RIG_FILE="$WORKDIR/$NAME-rig.json"
        log "  generating RIG…"
        (cd "$SRC_DIR" && bash "$EMITTERS_DIR/emit-rig.sh" "$RIG_FILE" "$SRC_LANG") || {
            log "  ERROR: emitter failed"
            patch_status "$NAME" "lastProcessedRevision" "FAILED: emitter error"
            continue
        }

        log "  validating RIG…"
        COMPONENT_COUNT=$(python3 -c "
import json
with open('$RIG_FILE') as f:
    rig = json.load(f)
assert 'components' in rig, 'missing components'
assert 'repository' in rig, 'missing repository'
print(len(rig['components']))
" 2>/dev/null) || {
            log "  ERROR: RIG validation failed"
            patch_status "$NAME" "lastProcessedRevision" "FAILED: invalid RIG"
            continue
        }
        EDGE_COUNT=$(python3 -c "
import json
with open('$RIG_FILE') as f:
    rig = json.load(f)
print(sum(len(c.get('depends_on_ids',[])) for c in rig['components']))
" 2>/dev/null)
        log "    $COMPONENT_COUNT components, $EDGE_COUNT edges"

        ARTIFACT_SHA="$(sha256sum "$RIG_FILE" | cut -c1-16)"
        mkdir -p "$WIKI_DIR/$DST_DIR"
        cp "$RIG_FILE" "$WIKI_DIR/$DST_DIR/rig.json"

    elif [ "$WORKFLOW" = "generic" ]; then
        # ── Generic: copy source as raw material ──

        log "  copying source to $DST_DIR…"
        mkdir -p "$WIKI_DIR/$DST_DIR"
        rsync -a --delete --exclude='.git' "$SRC_DIR/" "$WIKI_DIR/$DST_DIR/"
        ARTIFACT_SHA="$ARTIFACT_REV"
    fi

    # Commit + push
    CHANGED=false
    (cd "$WIKI_DIR" && \
        git add -A && \
        git diff --cached --quiet && log "  no changes (identical to existing)") || {
        (cd "$WIKI_DIR" && \
            git -c user.name="llm-wiki-bot" \
                -c user.email="wiki-bot@llm-wiki.dev" \
                commit -m "chore($WORKFLOW): auto-update $NAME" && \
            git push origin "$DST_BRANCH") || {
            log "  ERROR: cannot push to wiki repo"
            patch_status "$NAME" "lastProcessedRevision" "FAILED: push error"
            continue
        }
        CHANGED=true
        log "  pushed update"
    }

    # Update Kubernetes status
    patch_status "$NAME" "lastProcessedRevision" "$ARTIFACT_REV"
    [ -n "$ARTIFACT_SHA" ] && patch_status "$NAME" "lastRigSha256" "$ARTIFACT_SHA"

    # Update Dapr state cache
    dapr_save "$NAME:processed_revision" "$ARTIFACT_REV"
    dapr_save "$NAME:rig_sha256" "$ARTIFACT_SHA"
    [ -n "${COMPONENT_COUNT:-}" ] && dapr_save "$NAME:component_count" "$COMPONENT_COUNT"
    [ -n "${EDGE_COUNT:-}" ] && dapr_save "$NAME:edge_count" "$EDGE_COUNT"
    dapr_save "$NAME:last_run_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Run the LLM agent step if content changed OR status was reset
    FORCE_SYNC=false
    [ -z "$LAST_REV" ] && FORCE_SYNC=true
    if { $CHANGED || $FORCE_SYNC; } && [ -f /usr/local/bin/agent-sync.sh ]; then
        if $FORCE_SYNC && ! $CHANGED; then
            log "  running agent sync ($WORKFLOW) [forced — status was reset]…"
        else
            log "  running agent sync ($WORKFLOW)…"
        fi
        /usr/local/bin/agent-sync.sh "$WIKI_DIR" "$NAME" "$WORKFLOW" || {
            log "  WARN: agent sync failed (non-fatal)"
        }

        # Publish event: docs updated
        dapr_publish "wiki.docs.updated" \
            "{\"project\":\"$NAME\",\"revision\":\"$ARTIFACT_REV\",\"workflow\":\"$WORKFLOW\",\"components\":${COMPONENT_COUNT:-0}}"
    fi

    log "  DONE ✓"
done

log "Reconciliation complete."

# ── Gracefully shut down the Dapr sidecar ──
# Without this, the daprd container keeps running after the main container
# exits, preventing the Job/Pod from completing.
# Always attempt shutdown even if health check failed earlier (sidecar
# may have become ready after the initial check).
log "Shutting down Dapr sidecar…"
curl -sf -X POST http://localhost:3500/v1.0/shutdown >/dev/null 2>&1 || true
sleep 5
