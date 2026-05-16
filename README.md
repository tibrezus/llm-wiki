# llm-wiki

A shared tooling module for [LLM Wiki](./llm-wiki.md) instances — the persistent, compounding knowledge base pattern for LLM agents.

This repository is used as a **git submodule** inside wiki instances. It provides linting, testing, CI pipelines, and the wiki schema so that structure, correctness, and tooling are maintained centrally and shared across projects.

## What's Included

| Component | Path | Purpose |
|-----------|------|---------|
| Wiki Schema | `AGENTS.md` | Page format, frontmatter rules, workflows, naming conventions |
| Pattern Document | `llm-wiki.md` | The original LLM Wiki idea document |
| Page Frontmatter Schema | `schemas/wiki-page.schema.yaml` | JSON Schema for wiki page YAML frontmatter |
| Config Schema | `schemas/wiki-config.schema.yaml` | JSON Schema for `wiki.config.yml` |
| Health Checker | `scripts/wiki-health.py` | Structural validation (orphans, bidirectional links, type/directory match, etc.) |
| Config Validator | `scripts/validate-config.py` | Validates `wiki.config.yml` against schema |
| Consistency Check | `scripts/ci-consistency.sh` | Detects drift between generated files and current config |
| QMD Setup | `scripts/qmd-setup.sh` | Search engine setup reading from `wiki.config.yml` |
| CI Lint Pipeline | `scripts/ci-lint.sh` | Full lint pipeline (markdownlint, mdlint-obsidian, remark, health check) |
| CI Index Pipeline | `scripts/ci-index.sh` | QMD index build, embed, health verification |
| Bootstrap Script | `scripts/bootstrap.sh` | Initialize a new wiki instance with interactive prompts |
| Reusable Lint Workflow | `.github/workflows/lint.yml` | GitHub Actions reusable workflow for lint + consistency |
| Reusable Index Workflow | `.github/workflows/index.yml` | GitHub Actions reusable workflow for QMD indexing |
| Shared Config Reader | `scripts/lib/config.sh` | `read_config()`, `require_config()`, `require_submodule()` |
| Shared Generators | `scripts/lib/generate.sh` | File generators (package.json, qmd.yml, CI workflow, etc.) |
| Shared Tool Installer | `scripts/lib/install-tools.sh` | `install_all_lint_tools()`, `install_qmd()`, etc. |
| Markdown Lint | `.markdownlint.yaml` | Shared markdown formatting rules |
| Pre-Commit Hooks | `.pre-commit-config.yaml` | Automated validation on every commit |
| Tests | `tests/test_wiki_health.py` | Unit tests for wiki-health.py check functions |

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
- Generate `.github/workflows/wiki-ci.yml` using the module's reusable workflows
- Create `wiki/` directory structure (`entities/`, `concepts/`, `guides/`, `reference/`)
- Install npm dependencies and pre-commit hooks

## Instance CI

The generated CI workflow calls the module's reusable workflows:

```yaml
# Generated .github/workflows/wiki-ci.yml
jobs:
  lint:
    uses: tibrezus/llm-wiki/.github/workflows/lint.yml@main
    with:
      runner: self-hosted
      node-version: "20"

  index:
    uses: tibrezus/llm-wiki/.github/workflows/index.yml@main
    needs: lint
    with:
      runner: self-hosted
      node-version: "20"
```

The lint workflow runs:
1. **Consistency check** — verifies generated files match current `wiki.config.yml` and symlinks are correct
2. **Config validation** — validates `wiki.config.yml` against schema
3. **markdownlint** — markdown formatting
4. **mdlint-obsidian** — wikilinks, frontmatter, embeds
5. **remark** — frontmatter schema validation
6. **Unique filenames** — no duplicates across wiki/
7. **Raw/ immutability** — raw/ files not modified in PRs
8. **Wiki health check** — orphans, bidirectional links, type/directory match, stale pages

The index workflow runs:
1. **QMD setup** — collection + context from config
2. **Index + embed** — build search index
3. **Verify + search test** — confirm index health

When the module's CI scripts are updated, all instances get the changes on their next CI run (the reusable workflow is fetched from `@main`). The consistency check catches instances that need to re-run bootstrap.

## Instance Structure

After bootstrapping, a wiki instance looks like this:

```
my-wiki/
├── .llm-wiki/                          # This module (git submodule)
│   ├── AGENTS.md                       # Wiki schema
│   ├── llm-wiki.md                     # Pattern document
│   ├── schemas/                        # Frontmatter + config schemas
│   └── scripts/                        # Health check, CI pipelines, setup
├── AGENTS.md → .llm-wiki/AGENTS.md     # Symlink (auto-updates with submodule)
├── .markdownlint.yaml → .llm-wiki/...  # Symlink (auto-updates)
├── .pre-commit-config.yaml → .llm-wiki/... # Symlink (auto-updates)
├── .gitignore                          # Generated (git can't read symlinked gitignore)
├── .remarkrc.mjs                       # Generated (references .llm-wiki/schemas/)
├── wiki.config.yml                     # Project-specific configuration
├── package.json                        # npm dev dependencies
├── qmd.yml                             # QMD search config
├── .github/workflows/wiki-ci.yml       # CI (calls module's reusable workflows)
├── wiki/                               # Wiki content (instance-owned)
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

When this module is updated, all instances get the changes:

```bash
cd my-wiki
cd .llm-wiki && git pull origin main && cd ..
git add .llm-wiki
git commit -m "chore: update llm-wiki submodule"
```

Symlinked files auto-update. If the module changes template formats, CI's consistency check will fail and prompt:

```
Run 'bash .llm-wiki/scripts/bootstrap.sh' to regenerate drifted files.
```

Re-running bootstrap regenerates files from config while preserving content (`wiki/`, `raw/`, `index.md`, `log.md`).

## Project Configuration

Each instance defines its project context in `wiki.config.yml`, validated against `schemas/wiki-config.schema.yaml`:

```yaml
project:
  name: my-project          # required, lowercase hyphen-separated
  title: My Project         # required
  description: ...          # required
  url: https://...          # optional

qmd:
  global_context: "..."     # required, min 10 chars
  entity_context: "..."     # optional
  concept_context: "..."    # optional
  guide_context: "..."      # optional
  reference_context: "..."  # optional

ci:
  runner: ubuntu-latest     # optional, default ubuntu-latest
  node_version: "20"        # optional, default "20"
```

## Validation Tools

| Tool | Purpose | Install |
|------|---------|---------|
| markdownlint-cli2 | Markdown formatting | `npm install -g markdownlint-cli2` |
| mdlint-obsidian | Wikilinks, frontmatter, embeds | `pip install mdlint-obsidian` |
| remark-lint-frontmatter-schema | Frontmatter JSON Schema validation | `npm ci` |
| qmd | Local search engine (BM25 + vector + reranking) | `npm install -g @tobilu/qmd` |

Run all checks locally: `npm run check`

## Development

```bash
# Lint the module itself
npm run lint

# Run tests
npm run test

# Full check
npm run check
```
