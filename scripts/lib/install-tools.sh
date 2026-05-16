#!/usr/bin/env bash
set -euo pipefail

# Shared tool installation for CI and local development.
# Source this file: source "$(dirname "$0")/install-tools.sh"

install_node_tools() {
    echo "::group::Install Node.js tools"
    npm install -g markdownlint-cli2
    echo "::endgroup::"
}

install_python_tools() {
    echo "::group::Install Python tools"
    python3 -m pip install --break-system-packages pyyaml mdlint-obsidian 2>/dev/null \
        || pip3 install pyyaml mdlint-obsidian 2>/dev/null
    echo "::endgroup::"
}

install_remark_deps() {
    echo "::group::Install remark dependencies"
    npm ci 2>/dev/null || npm install
    echo "::endgroup::"
}

install_qmd() {
    echo "::group::Install QMD"
    npm install -g @tobilu/qmd
    if ! command -v bun &>/dev/null; then
        curl -fsSL https://bun.sh/install | bash
        echo "$HOME/.bun/bin" >> "${GITHUB_PATH:-/dev/null}"
    fi
    echo "::endgroup::"
}

install_all_lint_tools() {
    install_node_tools
    install_python_tools
    install_remark_deps
}

configure_path() {
    local npm_bin
    npm_bin="$(npm prefix -g 2>/dev/null)/bin"
    if [ -d "$npm_bin" ]; then
        echo "$npm_bin" >> "${GITHUB_PATH:-/dev/null}"
    fi
    local pip_bin="$HOME/.local/bin"
    if [ -d "$pip_bin" ]; then
        echo "$pip_bin" >> "${GITHUB_PATH:-/dev/null}"
    fi
}
