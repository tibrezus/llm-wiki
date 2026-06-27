#!/usr/bin/env bash
set -euo pipefail

# File generators for LLM Wiki instances.
# Source this file: source "$(dirname "$0")/generate.sh"
# Each function takes a destination directory as the first argument.

generate_agents_md() {
    local dest="$1"
    local submodule="$2"
    # The wiki schema lives at instance/AGENTS.md in the module and is copied
    # verbatim into the instance root as AGENTS.md.
    cp "$submodule/instance/AGENTS.md" "$dest/AGENTS.md"
}

generate_markdownlint() {
    local dest="$1"
    local submodule="$2"
    cp "$submodule/.markdownlint.yaml" "$dest/.markdownlint.yaml"
}

generate_pre_commit() {
    local dest="$1"
    local submodule="$2"
    cp "$submodule/.pre-commit-config.yaml" "$dest/.pre-commit-config.yaml"
}

generate_gitignore() {
    local dest="$1"
    echo "node_modules/" > "$dest/.gitignore"
}

generate_remarkrc() {
    local dest="$1"
    cat > "$dest/.remarkrc.mjs" <<'EOF'
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
EOF
}

generate_package_json() {
    local dest="$1"
    local title="$2"
    cat > "$dest/package.json" <<EOF
{
  "private": true,
  "type": "module",
  "description": "LLM Wiki for ${title} — dev dependencies for frontmatter validation",
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
EOF
}

generate_qmd_yml() {
    local dest="$1"
    local global="$2"
    local entity="$3"
    local concept="$4"
    local guide="$5"
    local reference="$6"
    cat > "$dest/qmd.yml" <<EOF
collections:
  wiki:
    path: ./wiki
    pattern: "**/*.md"

context:
  global: "${global}"
  paths:
    qmd://wiki/entities: "${entity}"
    qmd://wiki/concepts: "${concept}"
    qmd://wiki/guides: "${guide}"
    qmd://wiki/reference: "${reference}"
EOF
}

generate_ci_workflow() {
    local dest="$1"
    local runner="$2"
    local node_version="$3"
    local platform="${4:-github}"

    local wf_dir
    case "$platform" in
        forgejo) wf_dir="$dest/.forgejo/workflows" ;;
        gitea)   wf_dir="$dest/.gitea/workflows" ;;
        *)       wf_dir="$dest/.github/workflows" ;;
    esac
    mkdir -p "$wf_dir"

    cat > "$wf_dir/wiki-ci.yml" <<EOF
name: Wiki CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint:
    name: Lint, Validate, and Consistency
    runs-on: ${runner}
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: true

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "${node_version}"

      - name: Install pyyaml
        run: |
          if ! python3 -c 'import yaml' 2>/dev/null; then
            python3 -m pip install --user pyyaml 2>/dev/null \\
              || python3 -m pip install --break-system-packages pyyaml
          fi

      - name: Install lint tools
        run: bash .llm-wiki/scripts/lib/install-tools.sh && export PATH="\$HOME/.local/bin:\$PATH"

      - name: Install npm dependencies
        run: npm ci 2>/dev/null || npm install

      - name: Consistency check
        run: bash .llm-wiki/scripts/ci-consistency.sh

      - name: Lint pipeline
        run: |
          export PATH="\$HOME/.local/bin:\$PATH"
          bash .llm-wiki/scripts/ci-lint.sh

  index:
    name: QMD Index Health
    runs-on: ${runner}
    needs: lint
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: true

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "${node_version}"

      - name: Install pyyaml
        run: |
          if ! python3 -c 'import yaml' 2>/dev/null; then
            python3 -m pip install --user pyyaml 2>/dev/null \\
              || python3 -m pip install --break-system-packages pyyaml
          fi

      - name: Run index pipeline
        run: bash .llm-wiki/scripts/ci-index.sh
EOF

    # The arch job is emitted only when the instance declares arch.projects.
    local prev_cfg="${CONFIG_FILE:-}"
    if [ -f "$dest/wiki.config.yml" ]; then
        CONFIG_FILE="$dest/wiki.config.yml"
    fi
    if command -v config_has >/dev/null 2>&1 && config_has arch.projects; then
        cat >> "$wf_dir/wiki-ci.yml" <<EOF

  arch:
    name: Fetch + validate RIG architecture graphs
    runs-on: ${runner}
    needs: lint
    permissions:
      contents: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: true

      - name: Install pyyaml + jsonschema
        run: |
          python3 -m pip install --user pyyaml jsonschema 2>/dev/null \\
            || python3 -m pip install --break-system-packages pyyaml jsonschema

      - name: Fetch + validate RIG graphs
        run: bash .llm-wiki/scripts/arch/ci-arch.sh

      - name: Commit updated raw/arch artifacts
        run: |
          git config user.name  "llm-wiki-arch-bot"
          git config user.email "actions@noreply.example.com"
          if ! git diff --quiet -- raw/arch; then
            git add raw/arch
            git commit -m "chore(arch): update RIG architecture graphs [skip ci]"
            git push
          else
            echo "No changes to raw/arch artifacts."
          fi
EOF
    fi
    CONFIG_FILE="$prev_cfg"
}

generate_index() {
    local dest="$1"
    local title="$2"
    local date="$3"
    cat > "$dest/index.md" <<EOF
# Wiki Index

> Last updated: ${date}

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
}

generate_log() {
    local dest="$1"
    local title="$2"
    local date="$3"
    cat > "$dest/log.md" <<EOF
# Wiki Log

Chronological append-only activity log for the ${title} LLM Wiki.

## [${date}] create | Initial Wiki Bootstrap

- **Operation**: create
- **Pages affected**: None
- **Summary**: Bootstrapped the LLM Wiki instance using the llm-wiki template submodule. Created wiki.config.yml, directory structure, and initial index.md/log.md.
EOF
}

generate_readme() {
    local dest="$1"
    local name="$2"
    local title="$3"
    local description="$4"
    local url="$5"
    local url_line=""
    if [ -n "$url" ]; then
        url_line="[$title]($url) — "
    fi
    cat > "$dest/README.md" <<EOF
# ${name}

A persistent, compounding knowledge base for the ${url_line}${description}.

This wiki is maintained by LLM agents following the schema defined in \`AGENTS.md\`. It is designed to be browsed in [Obsidian](https://obsidian.md) for graph view and wikilink navigation, and searched with [qmd](https://github.com/tobi/qmd) for hybrid BM25/vector search with LLM re-ranking.

## Structure

\`\`\`text
${name}/
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

See \`.llm-wiki/instance/AGENTS.md\` for the full schema and \`llm-wiki.md\` for the original pattern document.
EOF
}
