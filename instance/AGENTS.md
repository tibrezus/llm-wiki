---
title: LLM Wiki Schema
---

# AGENTS.md — LLM Wiki Schema

This document is the authoritative schema for any LLM Wiki instance. Any LLM
agent working in a wiki repository must follow these conventions exactly.

The wiki is a **persistent, compounding artifact** — not a RAG index. Knowledge
is compiled once and kept current, not re-derived on every query. The human
curates sources and asks questions; you do all the writing, cross-referencing,
filing, and bookkeeping. This principle comes from `llm-wiki.md` (read it for
the full founding idea).

## Project Context

Each wiki instance defines its project-specific context in `wiki.config.yml` at
the repository root. **Read it at the start of every session** to understand the
domain (project name, description, URL), search-embedding contexts (QMD), CI
configuration, and which architecture projects are declared (if any).

## Repository Structure

```text
<instance-root>/
├── .llm-wiki/                    # Git submodule (shared tooling + schema)
│   ├── instance/AGENTS.md        # Source of THIS file (copied to instance root)
│   ├── llm-wiki.md               # Founding pattern document
│   ├── schemas/                  # JSON Schema for frontmatter + config
│   ├── scripts/                  # CI pipelines, health checks, arch tooling
│   └── .markdownlint.yaml        # Shared markdown rules
├── wiki.config.yml               # Project-specific configuration
├── AGENTS.md                     # Copied from .llm-wiki/instance/AGENTS.md
├── qmd.yml / package.json        # Generated from wiki.config.yml
├── index.md                      # Content-oriented catalog of all wiki pages
├── log.md                        # Chronological append-only activity log
├── raw/                          # Raw source documents (IMMUTABLE — never modify)
│   └── arch/                     # CI-generated code graphs (when configured)
└── wiki/                         # All wiki pages organized by entity type
    ├── entities/                 # Specific technologies and products
    ├── concepts/                 # Patterns and design principles
    ├── guides/                   # Step-by-step procedures
    └── reference/                # Catalogs, comparisons, lookup tables
```

## Three Layers

1. **Raw sources** (`raw/`) — Immutable. You read from them but NEVER modify,
   move, or delete. This is the source of truth, including CI-generated code
   graphs in `raw/arch/`.
2. **The wiki** (`wiki/`) — LLM-generated markdown pages. You own this layer
   entirely. You create pages, update them, maintain cross-references, and keep
   everything consistent.
3. **The schema** (`AGENTS.md` + `wiki.config.yml`) — Tells you how the wiki is
   structured and what workflows to follow.

## Entity Types

Pages are organized by **what kind of knowledge** they represent:

| Directory | Type | Search Intent | Classification Rule |
|-----------|------|--------------|-------------------|
| `entities/` | `entity` | "What is X?" — searched by name | Specific technology, product, or system |
| `concepts/` | `concept` | "How does X work?" — searched by description | Cross-cutting idea, pattern, or principle |
| `guides/` | `guide` | "How to X?" — searched by intent | Step-by-step procedure the reader follows |
| `reference/` | `reference` | "Compare/Lookup X" — searched by topic | Catalog, comparison, or lookup table |

## Page Format

Every wiki page must follow this exact structure:

```markdown
---
title: Descriptive Specific Title
type: entity | concept | guide | reference
created: YYYY-MM-DD
updated: YYYY-MM-DD
sources: []
tags: [type-tag, tag2, tag3]
---

# Descriptive Specific Title

Dense keyword-rich summary paragraph (2-3 sentences). Include primary search
terms and synonyms. This becomes the first and most important qmd chunk.

## Section Title

Body content with [[wikilinks]] to other wiki pages.

## See Also

- [[related-page-1]] — Brief description
- [[related-page-2]] — Brief description
```

### Frontmatter Rules

- `title` — Specific and descriptive. Embedded with every qmd chunk. Required.
- `type` — One of `entity`, `concept`, `guide`, `reference`. Must match the
  directory. Required.
- `created` — Date first created (YYYY-MM-DD). Never change after creation. Required.
- `updated` — Date of last meaningful content update. Update on every modification. Required.
- `sources` — Array of filenames from `raw/` that contributed. Empty array if none. Required.
- `tags` — 2-7 lowercase tags (pattern `^[a-z0-9][a-z0-9-]*$`). First tag must match the type. Required.

### Body Rules

- **Title rule**: `# Title` must be specific and descriptive — it becomes the
  embedding prefix for every qmd chunk.
- **Summary rule**: First paragraph must be a dense 2-3 sentence summary with
  primary keywords.
- **Section rule**: Each `## Section` should be 200-900 tokens. `##` headings are
  qmd chunk boundaries.
- **Cross-reference rule**: Include context with wikilinks — "See [[cilium]] for
  Cilium CNI configuration" not just "See [[cilium]]".
- **See Also rule**: Every page ends with `## See Also` linking to at least 2
  related pages.
- **Never use `#` headings** in body (reserved for title).
- **Never use markdown links** for internal references — always use `[[wikilinks]]`.

## Naming Conventions

- File names: lowercase, hyphen-separated, `.md` extension.
- **Unique filenames** — no two files in `wiki/` may share a name, regardless of
  directory. This enables filename-only wikilinks.
- Never use spaces, uppercase, or special characters.

## Cross-Referencing Rules

1. **Always use `[[wikilinks]]`** — filename only, no path, no extension.
2. **When creating a page**, scan all existing pages and add wikilinks where relevant.
3. **When updating a page**, check if new content mentions concepts with pages and
   add wikilinks.
4. **Every page must have `## See Also`** with at least 2 related pages.
5. **Bidirectional linking**: if A links to B, B should link back to A.
6. **Pipe wikilinks in tables**: avoid `[[page|display]]` inside markdown tables —
   the `|` conflicts with column delimiters.

---

## Documentation Workflows

The wiki supports distinct **documentation workflows**. Each workflow defines
its own inputs, diagram tool, and CI validation. A project can use one or both.
Additional workflows can be added following the same pattern (inputs → diagram
tool → CI validation → page conventions).

All workflows share the same **page format**, **entity types**, **naming**,
**cross-referencing rules**, and **shared operations** (Ingest, Query, Lint)
described above. What differs is the source of knowledge and how diagrams are
produced.

### Shared Operations

These operations apply regardless of which workflow you are in.

**Ingest** — When a new source arrives (any type):

1. Save the source to `raw/` with a descriptive filename. NEVER modify `raw/`.
2. Read the source thoroughly.
3. Update existing pages that should reflect the new information.
4. Create new pages for topics not yet covered.
5. Update `index.md` and append to `log.md`.

**Query** — When the human asks a question:

1. Use qmd to search: `qmd query "question" --json -n 10`.
2. Read relevant pages in full.
3. Synthesize an answer with citations.
4. If the answer is substantial, offer to file it as a new page.

**Lint** — Periodically health-check:

1. Run native linters: `markdownlint-cli2`, `mdlint --vault wiki/`, `npx remark
   wiki/ --frail`.
2. Run wiki health: `python3 .llm-wiki/scripts/wiki-health.py wiki/`.
3. Check for contradictions, orphan pages, missing cross-references.
4. Append a summary to `log.md`.

---

### Workflow 1: Generic Documentation

**For documenting anything that is not driven by a code graph.** This is the
default workflow. It covers entities (technologies, products), concepts
(patterns, principles), guides (procedures), and reference material (catalogs,
comparisons) — written from raw sources like articles, READMEs, conversations,
design docs, and observations.

- **Inputs**: raw sources in `raw/` (markdown articles, text files, images,
  design docs, etc.). Generic — anything the human curates.
- **Diagram tool**: **Mermaid only**. Mermaid renders natively on GitHub and in
  Obsidian (the primary surfaces for these wikis) and offers purpose-built
  diagram types. No D2 in this workflow.
- **CI validation**: the wiki CI validates that every page's markdown is
  well-formed and every Mermaid block is syntactically valid. This is the
  source of determinism for this workflow — the LLM writes freely, CI catches
  broken markdown/diagrams.

#### Mermaid diagrams (Generic Workflow)

Embed diagrams as fenced ` ```mermaid ` blocks inline in the page, next to the
prose they illustrate — like figures in a textbook, not a separate section.

Choose the Mermaid type that matches what the diagram *is*:

| Content | Mermaid type | Examples |
|---------|-------------|----------|
| Time-ordered triggers (A causes B causes C) | `sequenceDiagram` | request flows, session flows, release pipelines |
| Nested topology / containment | `flowchart TD` + `subgraph` | service trees, deployment topology |
| Linear pipeline / fan-out | `flowchart LR` | data pipelines, build chains |
| Dependency chain (layers) | `flowchart TD` | kustomization chains, tier dependencies |
| Decision branches (yes/no) | `flowchart TD` with `{rhombus}` | verification logic, gating |
| State transitions | `stateDiagram-v2` | lifecycle, pod states |
| Schema / relationships | `erDiagram`, `classDiagram` | data models, type hierarchies |
| Timeline / phases | `gantt`, `journey` | rollout plans, user flows |

Use ` ```text ` (not a diagram block) for **file trees, numbered procedures,
pseudo-code, command output, and templates** — those are not graphs.

---

### Workflow 2: Architecture Documentation (C4D2)

> **⚠ CRITICAL — READ THIS BEFORE DOING ANYTHING IN THIS WORKFLOW ⚠**
>
> The deterministic SCIP code graph in `raw/arch/` is the **ONLY source of
> truth** for architecture diagrams. Every symbol, every dependency, every
> component boundary you draw in a C4/D2 diagram **MUST be traceable to a
> specific entry in `raw/arch/<project>.map.txt` or the `.scip` index**.
>
> **NEVER write architecture diagrams from your training data, from memory,
> or from what you "know" the project looks like.** Your knowledge of the
> project is irrelevant — the graph is the source of truth. If the graph says
> something different from what you remember, the graph is right.
>
> **No graph = no architecture workflow.** If `raw/arch/<project>.scip` does
> not exist for the project you are documenting, you **cannot** use this
> workflow. Use Workflow 1 (Generic Documentation) instead. Do not invent
> architecture diagrams.

**For documenting a project's architecture from its code, driven by a
deterministic code graph.** This workflow applies only to projects declared in
the `arch:` block of `wiki.config.yml` for which a graph exists in `raw/arch/`.

#### Prerequisite gate (do this first, every time)

Before writing or updating any architecture diagram:

1. **Verify the graph exists**: `ls raw/arch/<project>.scip
   raw/arch/<project>.map.txt`. If either is missing → **STOP**. You cannot
   use this workflow. Tell the human the graph is missing and must be
   generated by CI first.
2. **Read the map**: `cat raw/arch/<project>.map.txt`. This is your input —
   the ranked, token-budgeted rollup of the actual code structure.
3. **Every diagram you produce must be derived from what you read in the map**
   (or drill from the `.scip`). Symbols, clusters, dependencies — all come from
   the graph. You assign C4 levels to graph entities; you do not invent
   entities.

- **Inputs**: a **SCIP code graph** (`raw/arch/<project>.scip` +
  `<project>.map.txt`), produced deterministically by CI (either the project's
  CI publishes the `.scip` and the wiki fetches it, or the wiki's CI clones and
  indexes the project). The `.map.txt` is the ranked, token-budgeted rollup you
  actually read; the `.scip` binary never enters your context whole.
- **Diagram tool**: **D2 exclusively**. D2's inter-diagram dependencies (nested
  shapes, multi-board linking) are what make the C4 zoom hierarchy work —
  Context, Container, Component, and Code levels nest into and link to each
  other as a navigable structure. No Mermaid for C4 diagrams.
- **CI validation**: the wiki CI validates that every D2 block is syntactically
  valid (compiles via the `d2` CLI). This is the source of determinism — the
  graph is deterministic and the diagrams must be valid D2.

#### The C4 model + D2 hierarchy

C4 defines four zoom levels of architecture. D2's nested shapes and cross-board
links map directly onto this hierarchy:

| C4 Level | Scope | What to show | D2 technique |
|----------|-------|-------------|-------------|
| **Context** | the whole system + external actors; may span projects | systems, users, external dependencies | top-level shapes; links to Container boards |
| **Container** | one project / deployable system | processes, deployables, data stores | nested shapes inside a Context shape; links to Component boards |
| **Component** | one component / module within a container | modules, services, key packages | nested shapes inside a Container shape; links to Code boards |
| **Code** | a few files / packages | top-ranked symbols (by PageRank from the map) | nested shapes inside a Component shape |

The key D2 feature: a shape in one board can **link to** a shape in another
board (or nest within it), so a reader can zoom from Context → Container →
Component → Code by following the structure. This inter-diagram dependency is
why D2 is mandatory for this workflow — Mermaid has no equivalent.

#### How C4 levels are assigned (from the graph, not from memory)

**This is your job as the LLM** — the core value-add. But the value you add is
**interpreting the graph**, not replacing it. The graph gives you ranked
symbols and their reference edges. You read `<project>.map.txt`, drill the
`.scip` for specific neighborhoods when needed, and decide which **graph
clusters** are Context vs Container vs Component vs Code. The ranking
(PageRank) tells you what is load-bearing (high rank → prominent in the
diagram) versus incidental.

What you are doing: taking deterministic graph data and deciding the C4
level boundaries (which cluster is a Container, which is a Component).

What you are **NOT** doing: describing the architecture from your training
data, guessing what modules exist, or drawing what you think the project looks
like. If a symbol or dependency is not in the graph, it does not go in the
diagram. If the graph shows a structure you don't expect, you draw what the
graph shows.

#### Architecture-Sync workflow

When the graph for a project changes (CI regenerates `raw/arch/`):

1. **Detect change** — `git log -p -- raw/arch/` shows what moved.
2. **Read the map** — `cat raw/arch/<project>.map.txt`. Orient using the ranked
   clusters from the **graph**.
3. **Re-derive C4 levels** — assign **graph** symbols/clusters to levels.
   Every shape in your D2 diagram must correspond to a real entry in the map.
4. **Update D2 figures** in the pages that explain each topic, preserving the
   C4 nesting and cross-board links. Only include symbols/dependencies present
   in the graph.
5. **Update `index.md`** and **append to `log.md`**; list the graph file
   (`raw/arch/<project>.scip`) in `sources:` so the derivation is traceable.

#### Graph contract (for project CI)

A project enters this workflow by producing and exposing a **SCIP index**:

- **Format** — binary [SCIP](https://github.com/sourcegraph/scip) `Index` protobuf
  (`.scip`), from the language-native indexer (`scip-go`, `scip-typescript`,
  `scip-python`, …).
- **Name** — `<project>.scip`, matching the `name` in the wiki's `arch:` config.
- **Exposure** — an HTTPS URL the wiki CI can fetch (GitHub Release asset, public
  artifact URL). Declare it in the wiki as
  `graph: { source: fetch, scip_url: <url> }`.
- Alternatively, use `graph: extract` (default) and the wiki's CI clones the
  repo and indexes it itself — no project-side changes needed.

The tooling lives in `.llm-wiki/scripts/arch/` (`extract.sh`, `rollup.py`,
`scip.proto`). A project can call
`bash .llm-wiki/scripts/arch/extract.sh <src> <lang> '' <project>.scip` directly
in its own CI.

#### Multi-project

A wiki can document several projects. Each has its own graph. Context-level
figures routinely span projects (project A calls project B); resolve
cross-project symbols through SCIP global IDs, never by ambiguous local names.

---

### Adding new workflows

Additional documentation workflows can follow the same pattern: define the
**inputs** (what feeds the LLM), the **diagram tool** (if any), and the **CI
validation** (what the pipeline checks). Keep shared operations, page format,
and cross-referencing rules universal.

---

## Tooling Reference

### Validation Tools

| Tool | Purpose |
|------|---------|
| markdownlint-cli2 | Markdown formatting rules |
| mdlint-obsidian | Obsidian wikilinks, frontmatter, embeds |
| remark-lint-frontmatter-schema | Frontmatter validation against JSON Schema |
| qmd | Local search engine (BM25 + vector + reranking) |
| `d2` CLI | D2 diagram validation/rendering (Architecture workflow) |
| scip-\<lang\> | Code graph indexers (Architecture workflow) |

### CI Pipeline

The instance CI (`.github/workflows/wiki-ci.yml`) calls the module's reusable
workflows from `@main`:

1. **lint** — consistency → config validation → markdownlint → mdlint-obsidian →
   remark → unique filenames → raw/ immutability → wiki-health.
2. **index** — qmd setup → update → embed → status → search test.
3. **arch** (only when `arch:` is configured) — clones/fetches each project →
   SCIP index → ranked rollup → commits `raw/arch/*`.

The reusable workflows live in the module repo; updating them there updates all
instances. The consistency check (`ci-consistency.sh`) detects drift.

## File: index.md

Content-oriented catalog organized by entity type. Every wiki page must be
listed. Update on every ingest or page creation.

## File: log.md

Chronological append-only log:

```markdown
## [YYYY-MM-DD] operation | Short Title

- **Operation**: ingest | query | lint | create | update | arch-sync
- **Pages affected**: list of wiki pages
- **Summary**: what happened and why
```

## What NOT to Do

- **Never modify files in `raw/`** after placement
- **Never delete wiki pages** without explicit instruction
- **Never use inline HTML** in wiki pages
- **Never use `#` headings** in body (reserved for title)
- **Never use markdown links** for internal references — use `[[wikilinks]]`
- **Never leave a page without frontmatter**
- **Never create a page without `## See Also`**
- **Never skip updating `index.md`** after page changes
- **Never skip appending to `log.md`** after any operation
- **Never use D2 in the Generic workflow** — Mermaid only
- **Never use Mermaid for C4 architecture diagrams** — D2 only (the
  inter-diagram hierarchy is the point)
- **Never write architecture diagrams from memory or training data** — every
  symbol, dependency, and boundary MUST come from the graph in `raw/arch/`
- **Never use the Architecture workflow if no graph exists** — if
  `raw/arch/<project>.scip` is missing, use Generic Documentation instead
- **Never place a page in the wrong entity type directory**
