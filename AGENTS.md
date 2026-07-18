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
3. **Agent skill** — `.agents/skills/wiki/SKILL.md` (git submodule of `tibrezus/agents`), synced to `~/.agents/skills/wiki/`.
   Guides the LLM when operating on wiki content.

## Three Documents — Do Not Confuse Them

| File | Role |
|------|------|
| **This file** (`AGENTS.md`) | How to maintain the **module** (scripts, schemas, CI, chart, emitters) |
| `instance/AGENTS.md` | The **wiki schema** — page format, frontmatter, entity types, two documentation workflows. Copied verbatim into each instance's root `AGENTS.md` by `bootstrap.sh`. |
| `.agents/skills/wiki/SKILL.md` | The **agent skill** — commands for the pi.dev harness (`read`, `update`, `create`, `prune`, `list`, `arch-sync`, `consult`). Source of truth: `tibrezus/agents` repo (git submodule at `.agents/`). Synced to `~/.agents/skills/wiki/SKILL.md`. |

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
.agents/skills/wiki/SKILL.md         # Agent skill (submodule of tibrezus/agents; synced to ~/.agents/skills/wiki/)
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
    rig-to-c4.py                 # Deterministic RIG → LikeC4 model generator
    validate-rig.py             # Validate RIG against schema
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
.github/actions/repo-map/           # Universal RIG generator (also usable as GitHub Action)
  action.yml                        # Composite Action dispatch
  emit-rig.sh                       # Shell wrapper
  emit-rig.py                       # Slim entry point: detect → extract → validate → output
  rig/                              # Modular RIG package (Spade-aligned)
    model.py                        # Data types: Component, Runner, TestDefinition, Evidence, ...
    builder.py                      # RIGBuilder: ID assignment, evidence cache, name→ID resolution
    validator.py                    # Generation-time validation (refs/cycles/evidence=ERROR, completeness=WARN)
    extractors/                     # One module per build system
      base.py                       # Extractor ABC: detects() + extract(builder)
      go.py                         # Go: go list -json
      zig.py                        # Zig: build.zig static analysis + native C/CUDA tracing
      cargo.py                      # Rust: Cargo.toml manifest parsing
      npm.py                        # npm/TypeScript: package.json + workspaces
      python.py                     # Python: pyproject.toml + package discovery
      cmake.py                      # CMake: add_executable/add_library + standalone C fallback
      generic.py                    # Fallback: groups source files by language
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

- **This module** ships the Helm chart (CRD, ScaledJob/CronJob, RBAC), the controller
  scripts (`reconcile.sh`, `agent-sync.sh`, `ci-monitor.sh`), the universal emitter
  (`emit-rig.py`), and the Dockerfile. This is **build logic** — HOW to generate
  RIGs and documentation.
- **k8s-config** installs the chart via HelmRelease and creates WikiMap CR
  instances + Flux GitRepository CRs. This is **runtime logic** — WHICH repos
  map WHERE.

### Runtime: KEDA + Dapr + PVC Cache

The controller runs as a **KEDA ScaledJob** (scale-to-zero when idle). Each pod
gets a **Dapr sidecar** (state store + pub/sub via Valkey) and a **persistent
PVC cache** (bare git clones, Go/npm module caches). A separate **always-on
event-subscriber Deployment** consumes the `wiki.docs.updated` topic (Redis
pub/sub is fire-and-forget, so the consumer must be online continuously — it
cannot live inside the scale-to-zero controller).

```text
KEDA trigger (cron every 30m)
  │
  ├── Init: mkdir cache dirs on PVC
  │
  └── Controller Pod (transient, 2 containers):
       ├── daprd (Dapr sidecar) ──→ Valkey
       │     localhost:3500/v1.0/state/statestore/{key}
       │     localhost:3500/v1.0/publish/pubsub/{topic}
       │
       └── rig-controller:
            ├── dapr_load → skip if revision unchanged (sub-ms)
            ├── clone_or_fetch_wiki() → git fetch on PVC (sub-second)
            ├── emit-rig.py → GOMODCACHE on PVC (no re-download)
            ├── pi --print → agent generates docs
            ├── ci-monitor.sh → polls CI status
            ├── dapr_save revision + hash + component count
            ├── dapr_publish "wiki.docs.updated"  ──┐
            └── POST /v1.0/shutdown → pod terminates │
                                                     ▼  (Valkey pub/sub)
  Event-subscriber Deployment (always-on, 1 replica):
       ├── daprd (Dapr sidecar) — subscribed to wiki.docs.updated
       └── event-subscriber.py:
            ├── receives each doc-sync event
            └── records a Kubernetes Event (reason: DocsSynced) on the
                source WikiMap → `kubectl get events` / `kubectl describe
                wikimap <name>`
```

This is step 1 of the move from cron-batch to event-driven operation: the
subscriber is the first real consumer of the event bus, proving the Dapr
pub/sub path end-to-end and giving operators a visible audit trail. Later
steps add a durable ledger and a KEDA trigger driven by these events.

Helm chart values (independent toggles):

| Value | Effect |
|-------|--------|
| `keda.enabled` | ScaledJob (event-driven, scale-to-zero) vs CronJob (fallback) |
| `dapr.enabled` | Sidecar injection (state store + pub/sub abstraction) |
| `cache.enabled` | PVC mount at /cache (bare clones, module caches) |
| `sshKey.enabled` | SSH key for non-GitHub wiki push (Codeberg, Forgejo) |
| `subscriber.enabled` | Always-on event-subscriber Deployment (consumes `wiki.docs.updated`) |

When Dapr is absent, all `dapr_*` calls are no-ops (graceful degradation), and
the event subscriber has nothing to consume (it still runs but receives no
events).

### Event subscriber (`event-subscriber.py`)

The `wiki.docs.updated` event published at the end of every successful
reconcile needs a consumer, or it is silently dropped (Redis pub/sub retains
messages in a stream only as long as a consumer is subscribed). The subscriber
is a stdlib-only Python HTTP server deployed as an always-on Deployment:

- **Discovery**: Dapr reads `GET /dapr/subscribe` and subscribes the app to
  `pubsub` / `wiki.docs.updated`, delivering each event to `POST /events`.
- **Acknowledgement**: the handler returns `{"status":"SUCCESS"}` per the Dapr
  pub/sub app-callback contract — any other status is treated as retriable and
  causes an infinite redelivery loop.
- **Effect**: for each event it creates a Kubernetes `Event` (reason
  `DocsSynced`) on the source `WikiMap` CR via the in-cluster API, surfacing
  every doc sync as `kubectl get events` / `kubectl describe wikimap <name>`.
- **RBAC**: needs `events` `create`/`patch` (added to the controller `Role`).
- **Dual-stack**: binds `::` (IPv6 with `IPV6_V6ONLY=0`) so kubelet's IPv6 pod-IP
  liveness probe and Dapr's `127.0.0.1` loopback delivery both work.

### WikiMap CRD (`llm-wiki.dev/v1alpha1`)

```yaml
spec:
  workflow: lc4 | generic       # default: lc4
  source:
    repo: <url-or-gitrepository-name>
    branch: main
    language: go                 # hint for field alignment; auto-detected by emit-rig.py
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
2. For each: checks **Dapr state** first (`dapr_load NAME:processed_revision`),
   skips if unchanged (sub-millisecond, no clone/emit needed)
3. Falls back to K8s status check if Dapr absent
4. Resolves Flux artifact revision, downloads if needed
5. Fetches wiki repo via PVC bare clone (`clone_or_fetch_wiki`) —
   first run clones, subsequent runs `git fetch` (sub-second)
6. **LC4**: runs `emit-rig.py` → `rig.json`, validates, pushes to wiki
7. **Generic**: copies source to `raw/<project>/`, pushes to wiki
8. Saves state to Dapr (`dapr_save`) + patches `WikiMap.status`

### agent-sync.sh (LLM phase — runs if content changed)

Uses `pi --print` with the llm-wiki skill and GLM-5.2 (via ZAI):

- **LC4**: reads updated RIG, compares with `model.c4`, identifies
  added/deprecated/changed components, updates model + Mermaid, commits
- **Generic**: reads new source material, creates/updates wiki pages with
  Mermaid, commits

After the agent pushes, a **CI self-healing loop** (up to 3 retries):

1. `ci-monitor.sh` polls the CI run triggered by the push
2. If CI fails, re-invokes the agent with:
   - `ci-consistency.sh` first (gating check — fixes drift via `bootstrap.sh`)
   - `ci-lint.sh` for remaining errors
3. Agent fixes, pushes, CI monitored again

State is saved to Dapr after each phase: agent commit SHA, CI status,
component count, edge count. The Dapr sidecar is shut down at the end
(`POST /v1.0/shutdown`) so the pod terminates cleanly.

Env vars: `LLM_WIKI_ZAI_TOKEN`, `LLM_WIKI_GITHUB_TOKEN`,
`LLM_WIKI_CODEBERG_TOKEN`, `LLM_WIKI_RZC_TOKEN`,
`CACHE_DIR` (/cache), `DAPR_STATE_STORE` (statestore), `DAPR_PUBSUB` (pubsub).

### Controller image

```bash
docker build -t ghcr.io/tibrezus/llm-wiki-controller:0.1.0 .
docker push ghcr.io/tibrezus/llm-wiki-controller:0.1.0
```

Contains: Go, Python3, Node.js 22, pi.dev harness, likec4, kubectl, git.

### Adding a new language extractor

The RIG generator is modular: each build system is a self-contained extractor
in `rig/extractors/`. To add support for a new language/build system:

1. **Create `rig/extractors/<lang>.py`** — a class extending `Extractor`:

   ```python
   from rig.builder import RIGBuilder
   from rig.model import Component
   from rig.extractors.base import Extractor

   class MyLangExtractor(Extractor):
       name = "my-build-system"
       build_file = "MyBuild.txt"

       @staticmethod
       def detects() -> bool:
           from pathlib import Path
           return Path("MyBuild.txt").exists()

       def extract(self, builder: RIGBuilder) -> None:
           # Parse build file, create Components/Tests/Runners,
           # register them via builder.add_component(...), etc.
           # Express dependencies as NAMES; builder resolves to IDs.
           ...
   ```

2. **Register it** in `emit-rig.py` — add the class to `EXTRACTOR_CLASSES`
   (before `GenericExtractor`).
3. **Add the toolchain** to the Dockerfile if the extractor needs a compiler/runtime.
4. **`npm run check`**; commit; rebuild image.

Key conventions:

- Components express `depends_on` and `external_packages` as **names** (strings).
  The `RIGBuilder.build()` method resolves names → IDs. Extractors never track
  ID maps themselves.
- Evidence should cite **actual build-file line numbers**, not just `:1`. Use
  `builder.evidence_at(build_file, text, offset)` or `builder.evidence(f"{file}:{line}")`.
- Emit **runners** for test/build commands (e.g., `zig build test`, `cargo test`).
- Emit **aggregators** for meta-targets (`go-build-all`, `zig-build`).
- Populate **component artifacts** (output paths) for executables.

## RIG Pipeline (arXiv:2601.10112 / Spade)

The RIG (Repository Intelligence Graph) is the deterministic contract between
a project and the wiki. It is a graph of **evidence-backed** build artifacts:
components are BUILD TARGETS (not source files), evidence proves each node is
defined by the build system, and test definitions link tests to production code.

### Architecture

```text
harmostes (k8s) — the documentation engine
┌───────────────────────────────────────────────────────────────────┐
│ rig-emit plugin (deterministic)                                   │
│  ├─ clone project source repo                                     │
│  ├─ emit-rig.py    → rig.json                                     │
│  ├─ rig-to-c4.py   → model.c4                                     │
│  └─ likec4 gen mermaid → *.mmd                                    │
│                                                                   │
│ agent (probabilistic — LLM via LiteLLM)                           │
│  ├─ read rig.json (what changed)                                  │
│  ├─ embed *.mmd into wiki pages                                   │
│  ├─ write C4-level prose (context/container/component)            │
│  ├─ offload code-level details to platform wiki (gh/git)          │
│  └─ gate: wiki-lint                                               │
│                                                                   │
│ git-push plugin → push to wiki repo                               │
└───────────────────────────────────────────────────────────────────┘

Wiki Instance (CI = lint only)
┌───────────────────────────────────────────────────────────────────┐
│ ci-lint.sh   → markdownlint + remark + mermaid + likec4 + health   │
│ ci-index.sh  → QMD index build + search test                      │
│ NO arch job, NO RIG fetching, NO generation logic                 │
└───────────────────────────────────────────────────────────────────┘
```

### Core layers

| Layer | File | Responsibility |
|-------|------|---------------|
| **Model** | `rig/model.py` | Spade data types (dataclasses): `Component`, `Aggregator`, `Runner`, `TestDefinition`, `Evidence`, `ExternalPackage`, `Artifact` |
| **Builder** | `rig/builder.py` | `RIGBuilder`: ID assignment, evidence cache (dedup), name→ID resolution, auto-evidence, JSON assembly |
| **Validator** | `rig/validator.py` | Generation-time checks: dangling refs, cycles, duplicate IDs, evidence coverage (all ERROR), completeness (WARN) |
| **Extractors** | `rig/extractors/*.py` | One class per build system: `detects()` + `extract(builder)`. Express deps as names; builder resolves to IDs |

### Extractor contract

Each extractor:

1. `detects()` — checks if its build system is present (e.g., `go.mod` exists)
2. `extract(builder)` — parses the build file, registers `Component`s,
   `TestDefinition`s, `Runner`s, `Aggregator`s, `Evidence`, and
   `ExternalPackage`s with the builder

Dependencies are expressed as **names** during extraction. The builder
resolves names → IDs in `build()`, so extractors never track ID maps.

### Spade alignment (paper compliance)

The implementation follows the RIG standard (arXiv:2601.10112,
github.com/Greenfuze/spade):

| Paper requirement | Implementation |
|-------------------|---------------|
| Components are build targets | Each extractor discovers executables/libraries from the build system |
| Every node has evidence | Builder auto-generates evidence (build-file ref + source-file ref) |
| Evidence = file:line refs | `Evidence.line` (flat refs) + `Evidence.call_stack` (ordered chain) |
| No dangling references | Validator: ERROR |
| No circular dependencies | Validator: ERROR (DFS cycle detection) |
| No duplicate IDs | Validator: ERROR |
| Test definitions link to components | `test_framework`, `components_being_tested_ids`, `test_executable_component_id` |
| Runners execute commands | Emitted per language (`go test`, `zig build test`, `cargo test`, `pytest`, `ctest`) with `arguments` |
| Aggregators are meta-targets | Emitted per language (`go-build-all`, `zig-build`, `go-test-all`) |
| External packages have manager metadata | Every package: `package_manager.name` + `package_manager.package_name` |
| Every source file in a component | Completeness check (WARN — repos with mixed languages may have files outside build targets) |

### Schema (`schemas/repo-map.schema.yaml`)

The schema enforces `additionalProperties: false` on every node type. Fields:

- **components**: `id`, `name`, `type` (executable/shared_library/static_library/package_library/vm/interpreted/unknown), `programming_language`, `source_files`, `depends_on_ids`, `external_packages_ids`, `evidence_ids`, `artifacts` (name + relative_path)
- **aggregators**: `id`, `name`, `depends_on_ids`, `evidence_ids`
- **runners**: `id`, `name`, `arguments`, `depends_on_ids`, `evidence_ids`
- **test_definitions**: `id`, `name`, `covers_ids`, `depends_on_ids`, `components_being_tested_ids`, `test_framework`, `test_executable_component_id`, `source_files`, `evidence_ids`
- **evidence**: `id`, `line` (file:line refs), `call_stack` (ordered chain, leaf first)
- **external_packages**: `id`, `name`, `package_manager` (name + package_name)
- **entrypoints**: component IDs (executables)

### Vendoring

The same `emit-rig.py` + `rig/` package is used in three places:

1. **GitHub Action** (`.github/actions/repo-map/`) — project CI publishes RIG as a release asset
2. **harmostes** (`plugins/rig-emit/`) — in-cluster controller generates RIG deterministically
3. **llm-wiki controller** (`deploy/`) — legacy GitOps controller

Changes to the module must be synced to the harmostes vendor copy:
`cp -r .github/actions/repo-map/{emit-rig.py,emit-rig.sh,rig} <harmostes>/plugins/rig-emit/`

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
- **The skill source of truth is `tibrezus/agents`** (git submodule at `.agents/`). Always sync: `cp .agents/skills/wiki/SKILL.md ~/.agents/skills/wiki/SKILL.md`.
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
