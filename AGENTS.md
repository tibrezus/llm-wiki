---
title: LLM Wiki — Shared Tooling Module
---

# AGENTS.md — llm-wiki (Shared Tooling Module)

> **You are in the `tibrezus/llm-wiki` module repository — NOT a wiki instance.**
> This repo will never contain `wiki/`, `raw/`, `wiki.config.yml`, `index.md`, or
> `log.md`. Do not look for them and do not follow instance workflows here.

This repository is the **shared tooling module** for the LLM Wiki system. It has
three layers:

1. **Wiki tooling** — schema, lint, CI pipelines, bootstrap, health checks.
   Consumed by wiki instances as a git submodule at `.llm-wiki/`.
2. **GitOps controller** — Helm chart + scripts + Dockerfile. Installed in
   Kubernetes via k8s-config to automatically generate RIGs and run the LLM
   agent pipeline.
3. **Agent skill** — `skill/SKILL.md`, synced to `~/.agents/skills/wiki/`.
   Guides the LLM when operating on wiki content.

## Three Documents — Do Not Confuse Them

| File | Role |
|------|------|
| **This file** (`AGENTS.md`) | How to maintain the **module** (scripts, schemas, CI, chart, emitters) |
| `instance/AGENTS.md` | The **wiki schema** — page format, frontmatter, entity types, two documentation workflows. Copied verbatim into each instance's root `AGENTS.md` by `bootstrap.sh`. |
| `skill/SKILL.md` | The **agent skill** — commands for the pi.dev harness (`read`, `update`, `create`, `prune`, `list`, `arch-sync`, `consult`). Synced to `~/.agents/skills/wiki/SKILL.md`. |

## Module ↔ Instance Relationship

Each wiki instance adds this repo as a git submodule at `.llm-wiki/` and runs
`bootstrap.sh`, which produces:

- **Copied** from module (must match submodule exactly): `AGENTS.md`
  (← `instance/AGENTS.md`), `.markdownlint.yaml`, `.pre-commit-config.yaml`.
- **Generated** from `wiki.config.yml`: `.gitignore`, `.remarkrc.mjs`,
  `package.json`, `qmd.yml`, CI workflow (`.github/workflows/`,
  `.forgejo/workflows/`, or `.gitea/workflows/` depending on `ci.platform`).
- **Instance-owned** (never regenerated): `wiki.config.yml`, `wiki/`, `raw/`,
  `index.md`, `log.md`, `README.md`.

The instance CI is **self-contained** — no cross-repo `uses:` references. Each
job inlines checkout + install + script calls. The `ci.platform` field in
`wiki.config.yml` controls the workflow directory and action URL prefix:

| Platform | Directory | Action URLs |
|----------|-----------|-------------|
| `github` | `.github/workflows/` | `actions/checkout@v4` |
| `forgejo` | `.forgejo/workflows/` | `https://code.forgejo.org/actions/checkout@v4` |
| `gitea` | `.gitea/workflows/` | `https://gitea.com/actions/checkout@v4` |

## Module Layout

```text
AGENTS.md                           # THIS FILE
instance/AGENTS.md                  # Wiki schema (copied into instances)
skill/SKILL.md                      # Agent skill (synced to ~/.agents/skills/wiki/)
schemas/
  wiki-page.schema.yaml             # Page frontmatter schema
  wiki-config.schema.yaml           # wiki.config.yml schema
  repo-map.schema.yaml              # RIG JSON schema
scripts/                            # Wiki instance tooling
  bootstrap.sh                      # Generate/regenerate from config
  new-wiki.sh                       # One-command instance creation
  ci-lint.sh                        # Lint: markdown + mermaid + likec4 + health
  ci-index.sh                       # QMD index build + verify
  ci-consistency.sh                 # Drift check (stale dirs, generated vs config)
  validate-config.py               # Validate wiki.config.yml
  validate-mermaid.py              # Render-check mermaid blocks (mmdc)
  wiki-health.py                   # Orphans, bidirectional links, type/dir
  arch/
    ci-arch.sh                      # Legacy RIG fetch (pre-GitOps)
    validate-rig.py                 # Validate RIG against schema
  lib/
    config.sh                       # read_config(), require_config()
    generate.sh                     # File generators (CI, package.json, etc.)
    install-tools.sh                # Tool installer (likec4, mmdc, etc.)
    puppeteer-config.json           # Headless Chromium config
deploy/                             # GitOps controller
  chart/                            # Helm chart (the operator)
    Chart.yaml
    values.yaml
    templates/
      crd-wikimap.yaml              # WikiMap CRD (llm-wiki.dev/v1alpha1)
      cronjob.yaml                  # Reconciliation CronJob
      role.yaml                     # RBAC (wikimaps + wikimaps/status + gitrepos)
      rolebinding.yaml
      serviceaccount.yaml
      _helpers.tpl
  scripts/
    reconcile.sh                    # Deterministic: download → emit/copy → push
    agent-sync.sh                   # LLM step: pi --print (GLM-5.2 via ZAI)
    add-wikimap.sh                  # One-command project onboarding
Dockerfile                          # Controller image (Go + Python3 + Node22 + pi + likec4)
.github/actions/repo-map/           # RIG emitters (also usable as GitHub Action)
  action.yml                        # Composite Action dispatch
  emit-go.sh                        # Go RIG emitter (go list -json)
  emit-zig.sh                       # Zig RIG emitter (build.zig + build.zig.zon)
tests/
  test_wiki_health.py
```

Module self-checks: `npm run check` (lint + test).

## Two Documentation Workflows

| Workflow | Input | Diagrams | CI validates | LLM command |
|----------|-------|----------|-------------|-------------|
| **Generic** | Raw sources (articles, READMEs) | Mermaid only | mermaid render | `wiki update` |
| **LC4** | RIG JSON (from code) | LikeC4 model → Mermaid | likec4 format + mermaid render | `wiki arch-sync` |

Both share the same page format, entity types, naming, and cross-referencing
rules defined in `instance/AGENTS.md`.

## GitOps RIG Controller

### Architecture (operator pattern)

- **This module** ships the Helm chart (CRD, CronJob, RBAC), the controller
  scripts (`reconcile.sh`, `agent-sync.sh`), the emitter scripts, and the
  Dockerfile. This is **build logic** — HOW to generate RIGs and documentation.
- **k8s-config** installs the chart via HelmRelease and creates WikiMap CR
  instances + Flux GitRepository CRs. This is **runtime logic** — WHICH repos
  map WHERE.

### WikiMap CRD (`llm-wiki.dev/v1alpha1`)

```yaml
spec:
  workflow: lc4 | generic       # default: lc4
  source:
    repo: <url-or-gitrepository-name>
    branch: main
    language: go                 # required for lc4, omitted for generic
  destination:
    wikiRepo: <git-url>
    wikiBranch: main
    projectDir: raw/arch/<project>  # or raw/<project> for generic
status:
  lastProcessedRevision: <sha>
  lastRigSha256: <hash>
```

### reconcile.sh (deterministic phase)

1. Lists WikiMap CRs via `kubectl get wikimaps`
2. For each: resolves Flux artifact revision, skips if unchanged
3. Downloads artifact (Flux source-controller or direct git clone)
4. **LC4**: runs `emit-<lang>.sh` → `rig.json`, validates, pushes to wiki
5. **Generic**: copies source to `raw/<project>/`, pushes to wiki
6. Patches `WikiMap.status.lastProcessedRevision`

### agent-sync.sh (LLM phase — runs if content changed)

Uses `pi --print` with the llm-wiki skill and GLM-5.2 (via ZAI):

- **LC4**: reads updated RIG, compares with `model.c4`, identifies
  added/deprecated/changed components, updates model + Mermaid, commits
- **Generic**: reads new source material, creates/updates wiki pages with
  Mermaid, commits

Env vars: `LLM_WIKI_ZAI_TOKEN` (ZAI API key from ExternalSecret/BSM),
`LLM_WIKI_GITHUB_TOKEN` (wiki push auth from ExternalSecret/BSM).

### Controller image

```bash
docker build -t ghcr.io/tibrezus/llm-wiki-controller:0.1.0 .
docker push ghcr.io/tibrezus/llm-wiki-controller:0.1.0
```

Contains: Go, Python3, Node.js 22, pi.dev harness, likec4, kubectl, git.

### Adding a new language emitter

1. Create `.github/actions/repo-map/emit-<lang>.sh` (follow `emit-go.sh` pattern)
2. Add the language to the CRD enum in `deploy/chart/templates/crd-wikimap.yaml`
3. Add to `emit-<lang>.sh` to the Dockerfile COPY
4. Add the toolchain to the Dockerfile (e.g., `cargo`, `pip`)
5. `npm run check`; commit; rebuild image

## Working in This Module

### Self-checks (run before pushing)

```bash
npm run check    # markdownlint + remark + pytest
```

### Principles

- **`instance/AGENTS.md` is the single source of truth for the wiki schema.**
  Editing it changes every instance on next bootstrap.
- **`scripts/lib/generate.sh` is the single source of truth for generated files.**
  Never hand-edit generated file contents.
- **`ci-consistency.sh` must know about every copied/generated file.** If you
  add a new artifact, update both `generate.sh` and `ci-consistency.sh`.
- **The skill is part of the module**: always sync `skill/SKILL.md` to
  `~/.agents/skills/wiki/SKILL.md` after changing it.
- **Backwards compatibility**: a change that breaks existing configs or pages
  will break every instance's CI simultaneously. Coordinate.

### Evolving the schema (`instance/AGENTS.md`)

1. Edit `instance/AGENTS.md`.
2. `npm run lint`.
3. If frontmatter/structure changed, update `schemas/wiki-page.schema.yaml`
   and `tests/test_wiki_health.py`.
4. Commit and push on `main`.

### Evolving the generators (`scripts/lib/generate.sh`)

1. Edit the relevant `generate_*` function.
2. Update `ci-consistency.sh` if new drift checks apply.
3. Smoke-test: `bash scripts/new-wiki.sh /tmp/wiki-smoke`.
4. `npm run check`; push on `main`.

### Evolving the controller (`deploy/`)

1. Edit scripts (`reconcile.sh`, `agent-sync.sh`) or chart templates.
2. Rebuild: `docker build -t ghcr.io/tibrezus/llm-wiki-controller:0.1.0 .`
3. Push image: `docker push ghcr.io/tibrezus/llm-wiki-controller:0.1.0`
4. Flux picks up chart changes via the `llm-wiki-module` GitRepository.
5. Force reconcile: `flux reconcile helmrelease llm-wiki-controller -n llm-wiki`

## Propagating a Module Change to Existing Instances

```bash
cd <instance-root>
git -C .llm-wiki fetch origin && git -C .llm-wiki checkout main && git -C .llm-wiki pull
bash .llm-wiki/scripts/bootstrap.sh   # regenerates/copies from config
git add -A
git commit -m "chore: update llm-wiki submodule + regenerate"
git push
# Watch CI: gh run watch (GitHub) / fj actions tasks (Forgejo/Codeberg)
```

A propagated change is not complete until CI is green on every affected instance.
