# llm-wiki

A shared tooling module for [LLM Wiki](./llm-wiki.md) instances — the persistent, compounding knowledge base pattern for LLM agents.

This repository is used as a **git submodule** inside wiki instances. It provides linting, testing, CI pipelines, and the wiki schema so that structure, correctness, and tooling are maintained centrally and shared across projects.

## What's Included

| Component | Path | Purpose |
|-----------|------|---------|
| Wiki Schema | `AGENTS.md` | Page format, frontmatter rules, workflows, naming conventions |
| Pattern Document | `llm-wiki.md` | The original LLM Wiki idea document |
| Frontmatter Schema | `schemas/wiki-page.schema.yaml` | JSON Schema for wiki page YAML frontmatter |
| Health Checker | `scripts/wiki-health.py` | Structural validation (orphans, bidirectional links, type/directory match, etc.) |
| QMD Setup | `scripts/qmd-setup.sh` | Search engine setup reading from `wiki.config.yml` |
| CI Lint Pipeline | `scripts/ci-lint.sh` | Full lint pipeline (markdownlint, mdlint-obsidian, remark, health check) |
| CI Index Pipeline | `scripts/ci-index.sh` | QMD index build, embed, health verification |
| Bootstrap Script | `scripts/bootstrap.sh` | Initialize a new wiki instance with interactive prompts |
| Markdown Lint | `.markdownlint.yaml` | Shared markdown formatting rules |
| Pre-Commit Hooks | `.pre-commit-config.yaml` | Automated validation on every commit |
| Remark Config | `.remarkrc.mjs` | Frontmatter schema validation via remark |
| npm Package | `package.json` | Dev dependencies for remark tools |

## Quick Start

Create a new wiki instance:

```bash
# 1. Create a new repository
mkdir my-wiki && cd my-wiki
git init

# 2. Add this module as a submodule
git submodule add https://github.com/tibrezus/llm-wiki.git .llm-wiki

# 3. Bootstrap the wiki
bash .llm-wiki/scripts/bootstrap.sh
```

The bootstrap script will:
- Prompt for project name, description, QMD contexts, and CI runner
- Create `wiki.config.yml` with project-specific configuration
- Generate symlinks to shared lint configs
- Generate `.remarkrc.mjs`, `package.json`, `qmd.yml`, `README.md`
- Create `wiki/` directory structure (`entities/`, `concepts/`, `guides/`, `reference/`)
- Generate `.github/workflows/wiki-ci.yml` for CI
- Install npm dependencies and pre-commit hooks

## Instance Structure

After bootstrapping, a wiki instance looks like this:

```
my-wiki/
├── .llm-wiki/                          # This module (git submodule)
│   ├── AGENTS.md                       # Wiki schema
│   ├── llm-wiki.md                     # Pattern document
│   ├── schemas/wiki-page.schema.yaml   # Frontmatter schema
│   └── scripts/                        # Health check, CI pipelines, setup
├── AGENTS.md → .llm-wiki/AGENTS.md     # Symlink
├── .markdownlint.yaml → .llm-wiki/...  # Symlink
├── .pre-commit-config.yaml → .llm-wiki/... # Symlink
├── .gitignore → .llm-wiki/...          # Symlink
├── .remarkrc.mjs                       # Generated (references .llm-wiki/schemas/)
├── wiki.config.yml                     # Project-specific configuration
├── package.json                        # npm dev dependencies
├── qmd.yml                             # QMD search config
├── .github/workflows/wiki-ci.yml       # CI (calls .llm-wiki/scripts/)
├── wiki/                               # Wiki content (entity-owned)
│   ├── entities/
│   ├── concepts/
│   ├── guides/
│   └── reference/
├── raw/                                # Immutable source documents
├── index.md                            # Page catalog
├── log.md                              # Activity log
└── README.md                           # Project readme
```

## Updating Shared Tooling

When this module is updated (new lint rules, CI improvements, schema changes), all instances get the updates:

```bash
cd my-wiki
cd .llm-wiki && git pull origin main && cd ..
git add .llm-wiki
git commit -m "chore: update llm-wiki submodule"
```

Symlinked files (`AGENTS.md`, `.markdownlint.yaml`, `.pre-commit-config.yaml`, `.gitignore`) automatically pick up changes. Generated files (`.remarkrc.mjs`, `package.json`, `qmd.yml`, CI workflow) may need regeneration — re-run `bash .llm-wiki/scripts/bootstrap.sh` (it skips existing content files).

## Project Configuration

Each instance defines its project context in `wiki.config.yml`:

```yaml
project:
  name: my-project
  title: My Project
  description: Description of what this wiki covers
  url: https://example.com

qmd:
  global_context: "Rich description for search embeddings"
  entity_context: "Context for entities/"
  concept_context: "Context for concepts/"
  guide_context: "Context for guides/"
  reference_context: "Context for reference/"

ci:
  runner: self-hosted
  node_version: "20"
```

LLM agents read this file at the start of every session to understand the project domain (see `AGENTS.md`).

## Validation Tools

| Tool | Purpose | Install |
|------|---------|---------|
| markdownlint-cli2 | Markdown formatting | `npm install -g markdownlint-cli2` |
| mdlint-obsidian | Wikilinks, frontmatter, embeds | `pip install mdlint-obsidian` |
| remark-lint-frontmatter-schema | Frontmatter JSON Schema validation | `npm ci` (local devDependencies) |
| qmd | Local search engine (BM25 + vector + reranking) | `npm install -g @tobilu/qmd` |

Run all checks: `npm run check`

## Extending

To improve the shared tooling across all wiki instances:

1. Make changes in this repository
2. Test with an existing instance (update submodule, run `npm run check`)
3. Push to `main`
4. Update the submodule reference in each instance

The wiki-health.py script, CI pipelines, lint rules, and frontmatter schema are all maintained here. Individual wiki instances own only their content (`wiki/`, `raw/`, `index.md`, `log.md`) and project configuration (`wiki.config.yml`).
