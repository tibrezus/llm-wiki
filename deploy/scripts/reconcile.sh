#!/usr/bin/env bash
set -euo pipefail

# reconcile.sh — the controller's reconciliation loop.
#
# Runs inside the controller container (CronJob). For every WikiMap CR in the
# llm-wiki namespace:
#   1. resolve the source artifact (Flux GitRepository or direct git URL)
#   2. compare revision against status.lastProcessedRevision
#   3. if changed: download source, run emitter, validate RIG, push to wiki repo
#   4. patch the WikiMap status with the new revision
#
# Environment:
#   NAMESPACE   — the namespace to watch (default: llm-wiki)
#   EMITTERS_DIR — where emitter scripts live (default: /emitters)
#   SCHEMA      — path to repo-map.schema.yaml (default: /schema/repo-map.schema.yaml)

NAMESPACE="${NAMESPACE:-llm-wiki}"
EMITTERS_DIR="${EMITTERS_DIR:-/emitters}"
SCHEMA="${SCHEMA:-/schema/repo-map.schema.yaml}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# List all WikiMap CRs as JSON.
get_wikimaps() {
    kubectl get wikimaps -n "$NAMESPACE" -o json 2>/dev/null || {
        log "ERROR: cannot list wikimaps in $NAMESPACE"
        log "Is the CRD installed and RBAC configured?"
        return 1
    }
}

# Get the artifact URL + revision for a Flux GitRepository.
# Args: <repo-name> (the Flux GitRepository name in this namespace)
get_flux_artifact() {
    local repo_name="$1"
    kubectl get gitrepository "$repo_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.artifact.url}{"\t"}{.status.artifact.revision}' 2>/dev/null
}

# Download a Flux artifact tarball and extract it.
# Args: <artifact-url> <dest-dir>
download_artifact() {
    local url="$1" dest="$2"
    curl -fsSL "$url" | tar -xzf - -C "$dest"
}

# Patch WikiMap status.
# Args: <name> <key> <value>
patch_status() {
    local name="$1" key="$2" value="$3"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    kubectl patch wikimap "$name" -n "$NAMESPACE" --type=merge -p \
        "{\"status\":{\"${key}\":\"${value}\",\"lastRunAt\":\"${now}\"}}" \
        --subresource=status 2>/dev/null || \
    kubectl patch wikimap "$name" -n "$NAMESPACE" --type=merge -p \
        "{\"status\":{\"${key}\":\"${value}\",\"lastRunAt\":\"${now}\"}}" 2>/dev/null || \
    log "  WARN: could not patch status for $name (subresource may not be enabled)"
}

# --- Main reconciliation loop ---

ITEMS_JSON="$(get_wikimaps)"
COUNT=$(echo "$ITEMS_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['items']))")

if [ "$COUNT" -eq 0 ]; then
    log "No WikiMap CRs found in $NAMESPACE — nothing to do."
    exit 0
fi

log "Reconciling $COUNT WikiMap(s)…"

# Process each WikiMap
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
    log "  dest:   $DST_WIKI:$DST_BRANCH/$DST_DIR"

    # Resolve the source artifact
    ARTIFACT_URL=""
    ARTIFACT_REV=""
    if kubectl get gitrepository "$SRC_REPO" -n "$NAMESPACE" &>/dev/null; then
        # SRC_REPO is a Flux GitRepository name
        ARTIFACT_DATA="$(get_flux_artifact "$SRC_REPO")" || true
        ARTIFACT_URL="$(echo "$ARTIFACT_DATA" | cut -f1)"
        ARTIFACT_REV="$(echo "$ARTIFACT_DATA" | cut -f2)"
    else
        # SRC_REPO is a direct git URL — clone and derive a revision
        log "  cloning $SRC_REPO (direct git URL)…"
        SRC_DIR="$WORKDIR/$NAME-src"
        git clone --depth 1 --branch "$SRC_BRANCH" "$SRC_REPO" "$SRC_DIR" 2>/dev/null || {
            log "  ERROR: cannot clone $SRC_REPO"
            patch_status "$NAME" "lastProcessedRevision" "FAILED: clone error"
            continue
        }
        ARTIFACT_REV="$(git -C "$SRC_DIR" rev-parse --short HEAD)"
        ARTIFACT_URL=""  # no Flux artifact — already cloned
    fi

    [ -n "$ARTIFACT_REV" ] || { log "  ERROR: cannot resolve revision for $SRC_REPO"; continue; }
    log "  revision: $ARTIFACT_REV"

    # Skip if already processed
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

    # --- Workflow branching ---
    # LC4: generate RIG from source code, run architecture documentation
    # Generic: copy source as raw material, run generic documentation update

    WIKI_DIR="$WORKDIR/$NAME-wiki"
    ARTIFACT_SHA=""

    # Clone wiki repo (needed for both workflows)
    log "  cloning wiki repo…"
    WIKI_URL_AUTH="$DST_WIKI"
    if [ -n "${LLM_WIKI_GITHUB_TOKEN:-}" ] && echo "$DST_WIKI" | grep -q 'github.com'; then
        # GitHub HTTPS auth via token
        WIKI_URL_AUTH=$(echo "$DST_WIKI" | sed "s|https://github.com|https://x-access-token:${LLM_WIKI_GITHUB_TOKEN}@github.com|; s|git@github.com:|https://x-access-token:${LLM_WIKI_GITHUB_TOKEN}@github.com/|")
    fi
    # For SSH URLs (codeberg.org, etc.), configure git to use the mounted key
    if echo "$DST_WIKI" | grep -q '^ssh://'; then
        export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes"
    fi
    git clone --depth 1 --branch "$DST_BRANCH" "$WIKI_URL_AUTH" "$WIKI_DIR" 2>/dev/null || {
        log "  ERROR: cannot clone wiki repo"
        patch_status "$NAME" "lastProcessedRevision" "FAILED: wiki clone"
        continue
    }

    if [ "$WORKFLOW" = "lc4" ]; then
        # --- LC4: generate RIG ---

        EMITTER="$EMITTERS_DIR/emit-${SRC_LANG}.sh"
        if [ ! -f "$EMITTER" ]; then
            log "  ERROR: no emitter for language '$SRC_LANG'"
            patch_status "$NAME" "lastProcessedRevision" "FAILED: no emitter"
            continue
        fi

        RIG_FILE="$WORKDIR/$NAME-rig.json"
        log "  generating RIG…"
        (cd "$SRC_DIR" && bash "$EMITTER" "$RIG_FILE") || {
            log "  ERROR: emitter failed"
            patch_status "$NAME" "lastProcessedRevision" "FAILED: emitter error"
            continue
        }

        log "  validating RIG…"
        python3 -c "
import json
with open('$RIG_FILE') as f:
    rig = json.load(f)
assert 'components' in rig, 'missing components'
assert 'repository' in rig, 'missing repository'
print(f'    {len(rig[\"components\"])} components, {len(rig.get(\"external_packages\",[]))} external')
" || {
            log "  ERROR: RIG validation failed"
            patch_status "$NAME" "lastProcessedRevision" "FAILED: invalid RIG"
            continue
        }

        ARTIFACT_SHA="$(sha256sum "$RIG_FILE" | cut -c1-16)"
        mkdir -p "$WIKI_DIR/$DST_DIR"
        cp "$RIG_FILE" "$WIKI_DIR/$DST_DIR/rig.json"

    elif [ "$WORKFLOW" = "generic" ]; then
        # --- Generic: copy source as raw material ---

        log "  copying source to $DST_DIR…"
        mkdir -p "$WIKI_DIR/$DST_DIR"
        # Copy all files from the source into the wiki raw dir
        rsync -a --delete --exclude='.git' "$SRC_DIR/" "$WIKI_DIR/$DST_DIR/"
        ARTIFACT_SHA="$ARTIFACT_REV"
    fi

    # Commit + push (both workflows)
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

    # Update status
    patch_status "$NAME" "lastProcessedRevision" "$ARTIFACT_REV"
    [ -n "$ARTIFACT_SHA" ] && patch_status "$NAME" "lastRigSha256" "$ARTIFACT_SHA"

    # Run the LLM agent step if content changed OR status was reset
    # (forced re-sync — model may be stale after emitter upgrades)
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
    fi

    log "  DONE ✓"
done

log "Reconciliation complete."
