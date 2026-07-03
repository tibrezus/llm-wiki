#!/usr/bin/env bash
set -euo pipefail

# add-wikimap.sh — add a project to the llm-wiki RIG pipeline.
#
# Usage:
#   add-wikimap.sh <project-name> <repo-url> <language> [options]
#
# Options:
#   --branch <branch>        Source branch (default: main)
#   --wiki <wiki-repo-url>   Wiki repository URL (default: git@github.com:rezuscloud/llm-wiki.git)
#   --wiki-branch <branch>   Wiki branch (default: main)
#   --dir <path>             Project dir in wiki (default: raw/arch/<project-name>)
#   --k8s-config <path>      Path to k8s-config repo (default: auto-detect)
#   --push                    Commit and push after creating
#
# Example:
#   add-wikimap.sh my-service https://github.com/me/my-service go
#
# This creates a single WikiMap CR in llm-wiki-instances/ and adds it to the
# kustomization. The controller picks it up on the next 30m cycle.
# For private repos, see the README in llm-wiki-instances/.

PROGNAME="$(basename "$0")"

usage() {
    sed -n 's/^# \?//p' "$0" | head -20
    exit 1
}

# At least project name + repo URL required. Language optional (3rd arg,
# only if it doesn't start with -).
if [ $# -lt 2 ]; then usage; fi
PROJECT_NAME="$1"
REPO_URL="$2"
LANGUAGE="none"
shift 2
# If the next arg is not a flag, it's the language
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    LANGUAGE="$1"
    shift
fi

BRANCH="main"
WIKI_REPO="git@github.com:rezuscloud/llm-wiki.git"
WIKI_BRANCH="main"
WORKFLOW="lc4"
PROJECT_DIR=""
K8S_CONFIG=""
DO_PUSH=false

while [ $# -gt 0 ]; do
    case "$1" in
        --branch)       BRANCH="$2"; shift 2 ;;
        --wiki)         WIKI_REPO="$2"; shift 2 ;;
        --wiki-branch)  WIKI_BRANCH="$2"; shift 2 ;;
        --workflow)     WORKFLOW="$2"; shift 2 ;;
        --dir)          PROJECT_DIR="$2"; shift 2 ;;
        --k8s-config)   K8S_CONFIG="$2"; shift 2 ;;
        --push)         DO_PUSH=true; shift ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

# Validate language (required for lc4, not generic)
if [ "$WORKFLOW" = "lc4" ]; then
    case "$LANGUAGE" in
        go|zig|python|rust|typescript) ;;
        *) echo "Error: unsupported language '$LANGUAGE' for lc4 workflow"; exit 1 ;;
    esac
fi

# Set default project dir based on workflow
if [ -z "$PROJECT_DIR" ]; then
    if [ "$WORKFLOW" = "generic" ]; then
        PROJECT_DIR="raw/${PROJECT_NAME}"
    else
        PROJECT_DIR="raw/arch/${PROJECT_NAME}"
    fi
fi

# Find k8s-config
if [ -z "$K8S_CONFIG" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    # Try common locations
    for candidate in \
        "$SCRIPT_DIR/../../../../operations/k8s-config" \
        "$HOME/source/repos/gitlab/tibrez/operations/k8s-config" \
        "$HOME/source/repos/*/operations/k8s-config"; do
        if [ -d "$candidate/llm-wiki-instances" ]; then
            K8S_CONFIG="$(cd "$candidate" && pwd)"
            break
        fi
    done
fi

if [ -z "$K8S_CONFIG" ] || [ ! -d "$K8S_CONFIG/llm-wiki-instances" ]; then
    echo "Error: cannot find k8s-config repo with llm-wiki-instances/"
    echo "Specify with --k8s-config <path>"
    exit 1
fi

INSTANCES_DIR="$K8S_CONFIG/llm-wiki-instances"
CR_FILE="$INSTANCES_DIR/wikimap-${PROJECT_NAME}.yaml"

if [ -f "$CR_FILE" ]; then
    echo "Error: $CR_FILE already exists"
    exit 1
fi

# Generate the WikiMap CR
# Build the language line conditionally
LANG_LINE=""
if [ "$LANGUAGE" != "none" ]; then
    LANG_LINE="    language: ${LANGUAGE}"
fi

cat > "$CR_FILE" << EOF
apiVersion: llm-wiki.dev/v1alpha1
kind: WikiMap
metadata:
  name: ${PROJECT_NAME}
  namespace: llm-wiki
  labels:
    app.kubernetes.io/name: llm-wiki
spec:
  workflow: ${WORKFLOW}
  source:
    repo: ${REPO_URL}
    branch: ${BRANCH}
${LANG_LINE}
  destination:
    wikiRepo: ${WIKI_REPO}
    wikiBranch: ${WIKI_BRANCH}
    projectDir: ${PROJECT_DIR}
EOF

echo "Created: $CR_FILE"

# Add to kustomization
KUSTOMIZATION="$INSTANCES_DIR/kustomization.yaml"
if ! grep -q "wikimap-${PROJECT_NAME}.yaml" "$KUSTOMIZATION"; then
    # Insert before the last line (maintaining alphabetical-ish order)
    sed -i "/wikimap-/a\\  - wikimap-${PROJECT_NAME}.yaml" "$KUSTOMIZATION"
    # Deduplicate in case of collision
    awk '!seen[$0]++' "$KUSTOMIZATION" > "${KUSTOMIZATION}.tmp" && mv "${KUSTOMIZATION}.tmp" "$KUSTOMIZATION"
    echo "Added to: $KUSTOMIZATION"
fi

if $DO_PUSH; then
    cd "$K8S_CONFIG"
    git add "$CR_FILE" "$KUSTOMIZATION"
    git commit -m "feat(llm-wiki): add ${PROJECT_NAME} to RIG pipeline"
    git push
    echo "Pushed. The controller will process ${PROJECT_NAME} on the next cycle (≤30m)."
else
    echo ""
    echo "To activate: cd $K8S_CONFIG && git add -A && git commit -m 'feat(llm-wiki): add ${PROJECT_NAME}' && git push"
fi
