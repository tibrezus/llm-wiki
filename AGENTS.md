---
title: LLM Wiki — Shared Tooling Module
---

# AGENTS.md — llm-wiki (Shared Tooling Module)

> **You are in the `tibrezus/llm-wiki` module repository — NOT a wiki instance.**
> This repo will never contain `wiki/`, `raw/`, `wiki.config.yml`, `index.md`, or
> `log.md`. Do not look for them and do not follow instance workflows here.

This repository is the **shared tooling module** used by every LLM Wiki instance
as a git submodule (`.llm-wiki/`). It supplies the wiki schema, lint config, CI
pipelines, and the bootstrap generator. Everything you change here propagates to
all instances. Work carefully and think about backwards compatibility.

## Two different AGENTS.md files — do not confuse them

| File | Where it lives | Role |
|------|---------------|------|
| **This file** (`AGENTS.md`) | Module root | How to maintain the **module** (scripts, schemas, CI, bootstrap) |
| `instance/AGENTS.md` | Module, at `instance/AGENTS.md` | The **wiki schema** — copied verbatim into each instance's root `AGENTS.md` by `bootstrap.sh` |

`instance/AGENTS.md` is titled **"LLM Wiki Schema"** and defines page format,
frontmatter rules, entity types, and two documentation workflows:

- **Workflow 1 — Generic Documentation**: documents anything from raw sources
  (articles, READMEs, conversations). Diagrams in **Mermaid only**. Wiki CI
  validates markdown + mermaid render validity.
- **Workflow 2 — Architecture Documentation (C4D2)**: documents a project's
  code structure from a deterministic RIG graph. Architecture models written
  in **LikeC4 DSL**, exported to **Mermaid** for rendering. CI validates the
  C4 model with `likec4 format --check`.

Both share the same page format, entity types, naming, and cross-referencing.
It is the authoritative contract every instance follows. **When editing wiki
content inside an instance, follow that instance's root `AGENTS.md` (= this
module's `instance/AGENTS.md`).**

## What this module provides

```text
AGENTS.md                       # THIS FILE — module maintenance guide
instance/AGENTS.md              # The wiki schema (copied into instances)
llm-wiki.md                     # Founding pattern document (reference)
README.md                       # Module overview + quick start
.markdownlint.yaml              # Shared markdown rules (copied into instances)
.pre-commit-config.yaml         # Pre-commit hooks (copied into instances)
.remarkrc.mjs                   # remark config (module self-lint)
package.json                    # npm: lint, test, check
skill/SKILL.md                  # Agent skill for wiki operations
schemas/
  wiki-page.schema.yaml         # JSON Schema for wiki page frontmatter
  wiki-config.schema.yaml       # JSON Schema for wiki.config.yml
instance/
  AGENTS.md                     # Wiki schema (source of the instance root AGENTS.md)
scripts/
  bootstrap.sh                  # Initialize/regenerate an instance from config
  new-wiki.sh                   # One-command creation of a brand-new instance
  ci-lint.sh                    # Full lint pipeline (used by reusable workflow)
  ci-index.sh                   # QMD index build + verify (reusable workflow)
  ci-consistency.sh             # Drift check (generated/copied files vs config)
  qmd-setup.sh                  # QMD collection + context from config
  validate-config.py            # Validate wiki.config.yml against schema
  wiki-health.py                # Orphans, bidirectional links, type/dir match…
  pre-commit-check.sh
  pre-commit-raw-protect.sh
  pre-commit-unique-filenames.sh
  lib/
    config.sh                   # read_config(), require_config(), require_submodule()
    generate.sh                 # File generators (package.json, qmd.yml, CI, …)
    install-tools.sh            # install_all_lint_tools(), install_qmd(), …
tests/
  test_wiki_health.py           # Unit tests for wiki-health.py checks
.github/workflows/
  lint.yml                      # Reusable lint workflow
  index.yml                     # Reusable index workflow
```

## Module ↔ instance relationship

Each instance adds this repo as a git submodule at `.llm-wiki/` and runs
`bootstrap.sh`, which produces an instance with:

- **Copied** from the module (must match the submodule exactly):
  `AGENTS.md` (← `instance/AGENTS.md`), `.markdownlint.yaml`, `.pre-commit-config.yaml`.
- **Generated** from `wiki.config.yml`:
  `.gitignore`, `.remarkrc.mjs`, `package.json`, `qmd.yml`,
  `.github/workflows/wiki-ci.yml`.
- **Instance-owned** (never regenerated, the human/agent's content):
  `wiki.config.yml`, `wiki/`, `raw/`, `index.md`, `log.md`, `README.md`.

Instance CI calls the module's **reusable** workflows, always pinned to `@main`:

- `tibrezus/llm-wiki/.github/workflows/lint.yml@main`
- `tibrezus/llm-wiki/.github/workflows/index.yml@main`

`ci-consistency.sh` verifies that an instance's copied/generated files still
match the current `wiki.config.yml` + submodule, and instructs the operator to
re-run `bootstrap.sh` if they have drifted.

## Working in this module

### Self-checks (run before pushing)

```bash
npm run lint    # markdownlint on module + instance/ markdown
npm run test    # pytest unit tests for wiki-health.py
npm run check   # lint + test
```

### Principles

- **`instance/AGENTS.md` is the single source of truth for the wiki schema.**
  Editing it changes every instance on its next bootstrap. Edit deliberately.
- **`scripts/lib/generate.sh` is the single source of truth for generated files.**
  Never hand-edit generated file contents — change the generator.
- **`ci-consistency.sh` must know about every copied/generated file.** If you add
  a new copied/generated artifact, update both `generate.sh` and
  `ci-consistency.sh`'s `GENERATED_FILES` / `COPIED_FILES` lists, plus the
  `copied_source()` mapping for any file whose submodule path differs from its
  instance path (as `AGENTS.md` does — it is sourced from `instance/AGENTS.md`).
- **Backwards compatibility.** A change that invalidates existing
  `wiki.config.yml` values or existing wiki pages will break every instance's CI
  simultaneously. Coordinate breaking changes across all instances in the same
  effort, or guard them so old instances keep passing.
- **No instance content here.** Never create `wiki/`, `raw/`, `wiki.config.yml`,
  `index.md`, or `log.md` in this repo.

### Evolving the schema (`instance/AGENTS.md`)

1. Edit `instance/AGENTS.md`. Keep the wiki schema there — do not duplicate it
   elsewhere.
2. `npm run lint` (the lint script includes `instance/*.md`).
3. If the change implies a frontmatter/structure change, update
   `schemas/wiki-page.schema.yaml` to match, and add/adjust
   `tests/test_wiki_health.py` + `wiki-health.py` accordingly.
4. Commit and push on `main`. Instances pick up the new schema on their next
   submodule bump + `bootstrap.sh` run.

### Evolving the generators (`scripts/lib/generate.sh`)

1. Edit the relevant `generate_*` function.
2. If the change affects what `ci-consistency.sh` should compare, update the
   `GENERATED_FILES`/`COPIED_FILES` lists and any path mapping.
3. Sanity-check generation by bootstrapping a throwaway instance:
   `bash scripts/new-wiki.sh /tmp/wiki-smoke` (interactive).
4. `npm run check`; push on `main`.

## Creating a new wiki instance

Two equivalent paths, both single-command from an empty directory:

**Option A — full creation from scratch (single command):**

```bash
bash /path/to/llm-wiki/scripts/new-wiki.sh my-wiki
# or, without a local clone of the module:
curl -fsSL https://raw.githubusercontent.com/tibrezus/llm-wiki/main/scripts/new-wiki.sh \
  | bash -s my-wiki
```

`new-wiki.sh` creates the directory, `git init`s it, adds the module as the
`.llm-wiki` submodule, then runs `bootstrap.sh` to generate all instance files.
The result is a ready-to-use wiki instance.

**Option B — when the submodule is already added:**

```bash
git submodule add https://github.com/tibrezus/llm-wiki.git .llm-wiki
bash .llm-wiki/scripts/bootstrap.sh
```

In both cases `bootstrap.sh` is the actual generator and is idempotent:
re-running it regenerates tooling files from `wiki.config.yml` while preserving
instance-owned content (`wiki/`, `raw/`, `index.md`, `log.md`, `README.md`).

## Propagating a module change to existing instances

```bash
cd <instance-root>
git -C .llm-wiki fetch origin && git -C .llm-wiki checkout main && git -C .llm-wiki pull
bash .llm-wiki/scripts/bootstrap.sh   # refresh copied/generated files
git add -A
git commit -m "chore: update llm-wiki submodule + regenerate"
npm run check                          # verify
```

Bootstrap re-copies `AGENTS.md` from `.llm-wiki/instance/AGENTS.md`, so an
instance's root `AGENTS.md` content stays identical before and after the split.

## Common tasks

- Lint + test the module: `npm run check`
- Lint just the schema doc: `npx markdownlint-cli2 'instance/*.md'`
- Validate an instance config (run in instance root):
  `python3 .llm-wiki/scripts/validate-config.py wiki.config.yml`
- Full instance health (run in instance root): `bash .llm-wiki/scripts/ci-lint.sh`
- Smoke-test a fresh instance: `bash scripts/new-wiki.sh /tmp/wiki-smoke`

## What NOT to do

- **Never** create `wiki/`, `raw/`, `wiki.config.yml`, `index.md`, or `log.md`
  in this module repo — it is tooling only.
- **Never** hand-edit generated file contents; edit the generator in
  `generate.sh`.
- **Never** let `instance/AGENTS.md` drift from the schema the instances actually
  follow — it is the canonical schema.
- **Never** ship a module change without `npm run check` passing and without
  considering its effect on all existing instances.
