#!/usr/bin/env bash
set -euo pipefail

# Extract a single project's code graph into a SCIP index.
#
# Usage:
#   extract.sh <src-dir> <language> [indexer] [out.scip]
#
#   <src-dir>   checked-out source tree to index
#   <language>  go | typescript | python | ruby | rust | java | kotlin | scala
#   [indexer]   optional override of the default scip-<language> binary
#   [out.scip]  output path (default: stdout-less; writes to <src-dir>/index.scip)
#
# The indexers are the project's native SCIP indexers (e.g. scip-go is built on
# gopls internals). They are installed on demand to ~/.local/bin and added to
# PATH. See install-indexer() for the per-language recipe.
#
# This script only produces the .scip; rollup (.map.txt) is done by ci-arch.sh.

SRC_DIR="${1:?Usage: extract.sh <src-dir> <language> [indexer] [out.scip]}"
LANGUAGE="${2:?missing language}"
INDEXER="${3:-}"
OUT="${4:-$SRC_DIR/index.scip}"

INDEXER="${INDEXER:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[extract]${NC} $*"; }
warn()  { echo -e "${YELLOW}[extract]${NC} $*"; }
error() { echo -e "${RED}[extract]${NC} $*" >&2; exit 1; }

default_indexer() {
    case "$1" in
        go)         echo "scip-go" ;;
        typescript|ts) echo "scip-typescript" ;;
        python|py)  echo "scip-python" ;;
        ruby|rb)    echo "scip-ruby" ;;
        rust|rs)    echo "scip-rust" ;;
        *)          echo "scip-$1" ;;
    esac
}

install_indexer() {
    local lang="$1" bin="$2"
    mkdir -p "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"
    if command -v "$bin" >/dev/null 2>&1; then
        info "indexer '$bin' already installed"
        return
    fi
    info "installing indexer '$bin' for language '$lang'..."
    case "$lang" in
        go)
            command -v go >/dev/null 2>&1 || error "scip-go needs 'go' on PATH."
            GOBIN="$HOME/.local/bin" go install github.com/sourcegraph/scip/go/cmd/scip-go@latest
            ;;
        typescript|ts)
            command -v npm >/dev/null 2>&1 || error "scip-typescript needs 'npm'."
            npm install -g @sourcegraph/scip-typescript
            ;;
        python|py)
            pip install --user scip-python || pip install --break-system-packages scip-python
            ;;
        ruby|rb)
            gem install scip-ruby 2>/dev/null || warn "scip-ruby may need manual install"
            ;;
        *)
            warn "No automatic install recipe for '$lang'; assuming '$bin' is on PATH."
            ;;
    esac
    command -v "$bin" >/dev/null 2>&1 || error "indexer '$bin' unavailable after install."
}

cd "$SRC_DIR"
if [ -z "$INDEXER" ]; then INDEXER="$(default_indexer "$LANGUAGE")"; fi
install_indexer "$LANGUAGE" "$INDEXER"
info "indexing with $INDEXER -> $OUT"

case "$LANGUAGE" in
    go)
        scip-go --output "$OUT"
        ;;
    typescript|ts)
        scip-typescript index --out "$OUT"
        ;;
    python|py)
        scip-python index . --output "$OUT"
        ;;
    rust|rs)
        scip-rust index --out "$OUT"
        ;;
    *)
        # Generic fallback: try a 'index --out' convention.
        "$INDEXER" index --out "$OUT" || "$INDEXER" --out "$OUT"
        ;;
esac

[ -s "$OUT" ] || error "indexer produced empty/missing output: $OUT"
info "SCIP index written: $OUT ($(wc -c < "$OUT") bytes)"
