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
    cat > "$dest/.gitignore" <<'EOF'
node_modules/
.obsidian/
EOF
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

    # Action URLs differ per platform:
    #   github  -> actions/checkout@v4 (resolves from github.com)
    #   forgejo -> https://code.forgejo.org/actions/checkout@v4
    #   gitea   -> https://gitea.com/actions/checkout@v4
    #
    # setup-node: GitHub runners need actions/setup-node to put npm on PATH.
    # Forgejo/Gitea self-hosted runners have Node pre-installed but the
    # setup-node action fails in their environment, so we skip it there.
    local checkout_action setup_node_block
    case "$platform" in
        forgejo)
            checkout_action="https://code.forgejo.org/actions/checkout@v4"
            setup_node_block=''
            ;;
        gitea)
            checkout_action="https://gitea.com/actions/checkout@v4"
            setup_node_block=''
            ;;
        *)
            checkout_action="actions/checkout@v4"
            setup_node_block="      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: \"${node_version}\""
            ;;
    esac

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
        uses: ${checkout_action}
        with:
          submodules: true
${setup_node_block}
      - name: Install python deps (pyyaml)
        run: bash .llm-wiki/scripts/install-python-deps.sh pyyaml

      - name: Install npm dependencies
        run: npm ci 2>/dev/null || npm install

      - name: Consistency check
        run: bash .llm-wiki/scripts/ci-consistency.sh

      - name: Lint pipeline
        run: bash .llm-wiki/scripts/ci-lint.sh

  index:
    name: QMD Index Health
    runs-on: ${runner}
    needs: lint
    steps:
      - name: Checkout
        uses: ${checkout_action}
        with:
          submodules: true
${setup_node_block}
      - name: Install python deps (pyyaml)
        run: bash .llm-wiki/scripts/install-python-deps.sh pyyaml

      - name: Run index pipeline
        run: bash .llm-wiki/scripts/ci-index.sh
EOF

    # The arch job is emitted only when the instance declares arch.projects.
    # config.sh sets CONFIG_FILE to the real repo root (instance root), which
    # is what we must read from even when generating into a temp dir (the
    # consistency check generates into TMPDIR, which has no wiki.config.yml).
    if command -v config_has >/dev/null 2>&1 && config_has arch.projects; then
        # Build env lines for private-project tokens (rig_token_env values).
        # Each maps the CI secret to an env var of the same name.
        ARCH_TOKEN_ENV=""
        if [ -f "$CONFIG_FILE" ]; then
            ARCH_TOKEN_ENV=$(python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f) or {}
seen = set()
for p in (c.get('arch') or {}).get('projects') or []:
    env = p.get('rig_token_env', '')
    if env and env not in seen:
        seen.add(env)
        print('          ' + env + ': \${{ secrets.' + env + ' }}')
" 2>/dev/null || true)
        fi
        # Only emit an `env:` block when there are private-project tokens;
        # an empty `env:` key is invalid YAML that breaks the workflow parse.
        ARCH_ENV_BLOCK=""
        if [ -n "$ARCH_TOKEN_ENV" ]; then
            ARCH_ENV_BLOCK="        env:
$ARCH_TOKEN_ENV"
        fi
        cat >> "$wf_dir/wiki-ci.yml" <<EOF

  arch:
    name: Fetch + validate RIG architecture graphs
    runs-on: ${runner}
    needs: lint
    permissions:
      contents: write
    steps:
      - name: Checkout
        uses: ${checkout_action}
        with:
          submodules: true

      - name: Install python deps (pyyaml + jsonschema)
        run: bash .llm-wiki/scripts/install-python-deps.sh pyyaml jsonschema

      - name: Fetch + validate RIG graphs
${ARCH_ENV_BLOCK}
        run: bash .llm-wiki/scripts/arch/ci-arch.sh

      - name: Commit updated raw/arch artifacts
        if: github.ref == format('refs/heads/{0}', github.event.repository.default_branch)
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
