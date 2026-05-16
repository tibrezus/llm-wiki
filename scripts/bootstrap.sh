#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a new LLM Wiki instance.
# Run from the instance repo root after adding the llm-wiki submodule:
#   git submodule add https://github.com/tibrezus/llm-wiki.git .llm-wiki
#   bash .llm-wiki/scripts/bootstrap.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBMODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTANCE_ROOT="$(cd "$SUBMODULE_DIR/.." && pwd)"
CONFIG_FILE="$INSTANCE_ROOT/wiki.config.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn()  { echo -e "${YELLOW}[bootstrap]${NC} $*"; }
error() { echo -e "${RED}[bootstrap]${NC} $*" >&2; exit 1; }

cd "$INSTANCE_ROOT"

# --- Prerequisites ---
[ -d ".llm-wiki" ] || error "Submodule not found at .llm-wiki/. Run: git submodule add https://github.com/tibrezus/llm-wiki.git .llm-wiki"

info "Bootstrapping LLM Wiki instance at $INSTANCE_ROOT"

# --- Collect project config ---
if [ -f "$CONFIG_FILE" ]; then
    warn "wiki.config.yml already exists. Skipping config prompts."
    warn "Delete wiki.config.yml and re-run to reconfigure."
else
    info "Configuring wiki instance..."

    read -rp "Project name (lowercase, hyphen-separated): " PROJECT_NAME
    [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || error "Invalid project name. Use lowercase letters, digits, and hyphens."

    read -rp "Project title (human-readable) [$PROJECT_NAME]: " PROJECT_TITLE
    PROJECT_TITLE="${PROJECT_TITLE:-$PROJECT_NAME}"

    read -rp "Project description (one sentence): " PROJECT_DESCRIPTION
    [ -n "$PROJECT_DESCRIPTION" ] || error "Project description is required."

    read -rp "Project URL (optional): " PROJECT_URL

    read -rp "QMD global context (rich description for search embeddings): " QMD_GLOBAL
    [ -n "$QMD_GLOBAL" ] || QMD_GLOBAL="Knowledge base for $PROJECT_TITLE"

    read -rp "QMD entity context [Specific technologies and products]: " QMD_ENTITY
    QMD_ENTITY="${QMD_ENTITY:-Specific technologies and products — each page describes one technology or product}"

    read -rp "QMD concept context [Architectural patterns and design principles]: " QMD_CONCEPT
    QMD_CONCEPT="${QMD_CONCEPT:-Architectural patterns and design principles connecting entities}"

    read -rp "QMD guide context [Step-by-step procedures]: " QMD_GUIDE
    QMD_GUIDE="${QMD_GUIDE:-Step-by-step procedures the reader follows}"

    read -rp "QMD reference context [Catalogs and lookup tables]: " QMD_REFERENCE
    QMD_REFERENCE="${QMD_REFERENCE:-Catalogs, comparisons, and lookup tables}"

    read -rp "CI runner [self-hosted]: " CI_RUNNER
    CI_RUNNER="${CI_RUNNER:-self-hosted}"

    read -rp "Node.js version [20]: " CI_NODE
    CI_NODE="${CI_NODE:-20}"

    cat > "$CONFIG_FILE" <<EOF
project:
  name: "$PROJECT_NAME"
  title: "$PROJECT_TITLE"
  description: "$PROJECT_DESCRIPTION"
  url: "${PROJECT_URL:-}"
qmd:
  global_context: "$QMD_GLOBAL"
  entity_context: "$QMD_ENTITY"
  concept_context: "$QMD_CONCEPT"
  guide_context: "$QMD_GUIDE"
  reference_context: "$QMD_REFERENCE"
ci:
  runner: "$CI_RUNNER"
  node_version: "$CI_NODE"
EOF
    info "Created wiki.config.yml"
fi

# Read config values (allows re-running with existing config)
read_config() {
    python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    config = yaml.safe_load(f)
keys = sys.argv[2].split('.')
val = config
for k in keys:
    val = val[k]
print(val)
" "$CONFIG_FILE" "$1"
}

PROJECT_NAME=$(read_config project.name)
PROJECT_TITLE=$(read_config project.title)
PROJECT_DESCRIPTION=$(read_config project.description)
PROJECT_URL=$(read_config project.url)
CI_RUNNER=$(read_config ci.runner)
CI_NODE=$(read_config ci.node_version)
QMD_GLOBAL=$(read_config qmd.global_context)
QMD_ENTITY=$(read_config qmd.entity_context)
QMD_CONCEPT=$(read_config qmd.concept_context)
QMD_GUIDE=$(read_config qmd.guide_context)
QMD_REFERENCE=$(read_config qmd.reference_context)

# --- Create symlinks to submodule configs ---
info "Creating symlinks..."

create_symlink() {
    local target="$1"
    local link="$2"
    if [ -L "$link" ]; then
        rm "$link"
    elif [ -e "$link" ]; then
        warn "$link already exists (not a symlink). Skipping. Remove it manually and re-run."
        return
    fi
    ln -s "$target" "$link"
    info "  $link -> $target"
}

create_symlink ".llm-wiki/AGENTS.md"            "$INSTANCE_ROOT/AGENTS.md"
create_symlink ".llm-wiki/.markdownlint.yaml"    "$INSTANCE_ROOT/.markdownlint.yaml"
create_symlink ".llm-wiki/.pre-commit-config.yaml" "$INSTANCE_ROOT/.pre-commit-config.yaml"

# .gitignore must be a real file (not symlinked) — git reads it before
# resolving submodule symlinks, causing "too many levels of symbolic links"
if [ ! -f "$INSTANCE_ROOT/.gitignore" ]; then
    info "Generating .gitignore..."
    echo "node_modules/" > "$INSTANCE_ROOT/.gitignore"
elif ! grep -q 'node_modules' "$INSTANCE_ROOT/.gitignore" 2>/dev/null; then
    echo "node_modules/" >> "$INSTANCE_ROOT/.gitignore"
fi

# --- Generate .remarkrc.mjs (local, references submodule schema) ---
info "Generating .remarkrc.mjs..."
cat > "$INSTANCE_ROOT/.remarkrc.mjs" <<'REMARK_EOF'
import remarkFrontmatter from "remark-frontmatter";
import remarkLintFrontmatterSchema from "remark-lint-frontmatter-schema";

const remarkConfig = {
  plugins: [
    remarkFrontmatter,
    [
      remarkLintFrontmatterSchema,
      {
        schemas: {
          "./.llm-wiki/schemas/wiki-page.schema.yaml": ["./wiki/**/*.md"],
        },
      },
    ],
  ],
};
export default remarkConfig;
REMARK_EOF

# --- Generate package.json ---
info "Generating package.json..."
cat > "$INSTANCE_ROOT/package.json" <<PKGEOF
{
  "private": true,
  "type": "module",
  "description": "LLM Wiki for ${PROJECT_TITLE} — dev dependencies for frontmatter validation",
  "devDependencies": {
    "remark-cli": "^12.0.0",
    "remark-frontmatter": "^5.0.0",
    "remark-lint-frontmatter-schema": "^3.0.0"
  },
  "scripts": {
    "lint": "markdownlint-cli2 'wiki/**/*.md' index.md log.md",
    "lint:fix": "markdownlint-cli2 --fix 'wiki/**/*.md' index.md log.md",
    "validate": "npx remark wiki/ --frail",
    "health": "python3 .llm-wiki/scripts/wiki-health.py wiki/",
    "check": "npm run lint && npm run validate && npm run health"
  }
}
PKGEOF

# --- Generate qmd.yml ---
info "Generating qmd.yml..."
cat > "$INSTANCE_ROOT/qmd.yml" <<QMDEOF
collections:
  wiki:
    path: ./wiki
    pattern: "**/*.md"

context:
  global: "${QMD_GLOBAL}"
  paths:
    qmd://wiki/entities: "${QMD_ENTITY}"
    qmd://wiki/concepts: "${QMD_CONCEPT}"
    qmd://wiki/guides: "${QMD_GUIDE}"
    qmd://wiki/reference: "${QMD_REFERENCE}"
QMDEOF

# --- Create wiki directory structure ---
info "Creating wiki directories..."
mkdir -p "$INSTANCE_ROOT/wiki/entities"
mkdir -p "$INSTANCE_ROOT/wiki/concepts"
mkdir -p "$INSTANCE_ROOT/wiki/guides"
mkdir -p "$INSTANCE_ROOT/wiki/reference"
mkdir -p "$INSTANCE_ROOT/raw"
touch "$INSTANCE_ROOT/raw/.gitkeep"

# --- Create index.md ---
if [ ! -f "$INSTANCE_ROOT/index.md" ]; then
    info "Creating index.md..."
    cat > "$INSTANCE_ROOT/index.md" <<EOF
# Wiki Index

> Last updated: $(date +%Y-%m-%d)

## Entities

Specific technologies and products. Searched by name ("what is X?").

| Page | Summary | Sources | Updated |
|------|---------|---------|---------|

## Concepts

Architectural patterns and design principles. Searched by description ("how does X work?").

| Page | Summary | Sources | Updated |
|------|---------|---------|---------|

## Guides

Step-by-step procedures. Searched by intent ("how to X?").

| Page | Summary | Sources | Updated |
|------|---------|---------|---------|

## Reference

Catalogs, comparisons, and lookup tables. Searched by topic.

| Page | Summary | Sources | Updated |
|------|---------|---------|---------|
EOF
else
    info "index.md already exists. Skipping."
fi

# --- Create log.md ---
if [ ! -f "$INSTANCE_ROOT/log.md" ]; then
    info "Creating log.md..."
    cat > "$INSTANCE_ROOT/log.md" <<EOF
# Wiki Log

Chronological append-only activity log for the ${PROJECT_TITLE} LLM Wiki.

## [$(date +%Y-%m-%d)] create | Initial Wiki Bootstrap

- **Operation**: create
- **Pages affected**: None
- **Summary**: Bootstrapped the LLM Wiki instance using the llm-wiki template submodule. Created wiki.config.yml, directory structure, and initial index.md/log.md.
EOF
else
    info "log.md already exists. Skipping."
fi

# --- Generate README.md ---
if [ ! -f "$INSTANCE_ROOT/README.md" ]; then
    info "Creating README.md..."
    URL_LINE=""
    if [ -n "$PROJECT_URL" ]; then
        URL_LINE="[$PROJECT_TITLE]($PROJECT_URL) — "
    fi
    cat > "$INSTANCE_ROOT/README.md" <<EOF
# ${PROJECT_NAME}

A persistent, compounding knowledge base for the ${URL_LINE}${PROJECT_DESCRIPTION}.

This wiki is maintained by LLM agents following the schema defined in \`AGENTS.md\`. It is designed to be browsed in [Obsidian](https://obsidian.md) for graph view and wikilink navigation, and searched with [qmd](https://github.com/tobi/qmd) for hybrid BM25/vector search with LLM re-ranking.

## Structure

\`\`\`text
${PROJECT_NAME}/
├── .llm-wiki/          # Shared tooling (git submodule)
├── wiki.config.yml     # Project-specific configuration
├── qmd.yml             # QMD search engine config
├── index.md            # Content-oriented catalog of all wiki pages
├── log.md              # Chronological append-only activity log
├── raw/                # Immutable source documents (never modify)
└── wiki/               # Wiki pages organized by entity type
    ├── entities/       # Specific technologies and products
    ├── concepts/       # Architectural patterns and design principles
    ├── guides/         # Step-by-step procedures
    └── reference/      # Catalogs and lookups
\`\`\`

## Setup

\`\`\`bash
# Install global validation tools
npm install -g markdownlint-cli2 @tobilu/qmd
pip install mdlint-obsidian

# Install local remark dependencies
npm ci

# Set up pre-commit hooks
pre-commit install

# Set up qmd search index
bash .llm-wiki/scripts/qmd-setup.sh
\`\`\`

## Validation

\`\`\`bash
# Run all checks
npm run check

# Individual tools
npm run lint          # markdownlint formatting
npm run validate      # frontmatter schema validation
npm run health        # structural wiki health check
\`\`\`

See \`.llm-wiki/AGENTS.md\` for the full schema and \`llm-wiki.md\` for the original pattern document.
EOF
else
    info "README.md already exists. Skipping."
fi

# --- Generate CI workflow ---
info "Generating .github/workflows/wiki-ci.yml..."
mkdir -p "$INSTANCE_ROOT/.github/workflows"
cat > "$INSTANCE_ROOT/.github/workflows/wiki-ci.yml" <<WFEOF
name: Wiki CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint:
    name: Lint and Validate
    runs-on: ${CI_RUNNER}
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: true

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "${CI_NODE}"

      - name: Run lint pipeline
        run: bash .llm-wiki/scripts/ci-lint.sh

  index:
    name: QMD Index Health
    runs-on: ${CI_RUNNER}
    needs: lint
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: true

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "${CI_NODE}"

      - name: Run index pipeline
        run: bash .llm-wiki/scripts/ci-index.sh
WFEOF

# --- Install dependencies ---
info "Installing npm dependencies..."
if command -v npm &>/dev/null; then
    npm ci 2>/dev/null || npm install
else
    warn "npm not found. Run 'npm ci' manually after installing Node.js."
fi

# --- Install pre-commit hooks ---
if command -v pre-commit &>/dev/null; then
    info "Installing pre-commit hooks..."
    pre-commit install 2>/dev/null || warn "pre-commit install failed. Run manually."
else
    warn "pre-commit not found. Install with: pip install pre-commit"
fi

# --- Summary ---
echo ""
info "========================================="
info "  LLM Wiki instance bootstrapped!"
info "========================================="
info ""
info "  Project:      $PROJECT_TITLE"
info "  Config:       wiki.config.yml"
info "  Submodule:    .llm-wiki/"
info ""
info "  Next steps:"
info "    1. Add content to wiki/ (see AGENTS.md for schema)"
info "    2. Drop source documents into raw/"
info "    3. Start your LLM agent and begin ingesting"
info "    4. Run 'npm run check' to validate"
info ""
info "  To update the shared tooling:"
info "    cd .llm-wiki && git pull origin main && cd .."
info ""
