---
title: LLM Wiki Schema
---

# AGENTS.md — LLM Wiki Schema

This document is the authoritative schema for any LLM Wiki instance. Any LLM agent working in a wiki repository must follow these conventions exactly. The wiki is a persistent, compounding knowledge base whose domain is defined by the project.

## Project Context

Each wiki instance defines its project-specific context in `wiki.config.yml` at the repository root. LLM agents **must read `wiki.config.yml`** at the start of every session to understand:

- What domain the wiki covers (project name, description, URL)
- How to optimize search embeddings (QMD context strings per directory)
- CI configuration (runner type, Node.js version)

The config file format:

```yaml
project:
  name: project-name          # Lowercase, hyphen-separated
  title: Project Name         # Human-readable
  description: One sentence   # Project description
  url: https://...            # Optional

qmd:
  global_context: "..."       # Rich description for search embeddings
  entity_context: "..."       # Context for wiki/entities/
  concept_context: "..."      # Context for wiki/concepts/
  guide_context: "..."        # Context for wiki/guides/
  reference_context: "..."    # Context for wiki/reference/

ci:
  runner: self-hosted         # GitHub Actions runner label
  node_version: "20"          # Node.js version
```

## Core Principle

This wiki is NOT a RAG index. It is a **persistent, compounding artifact**. Knowledge is compiled once and kept current — not re-derived on every query. When you add a source, you integrate it across the wiki. When you answer a question, good answers become new pages. Cross-references are maintained, contradictions are flagged, synthesis reflects everything ingested so far.

The human curates sources and asks questions. You do all the writing, cross-referencing, filing, and bookkeeping.

## Repository Structure

```text
<instance-root>/
├── .llm-wiki/                    # Git submodule (shared tooling)
│   ├── AGENTS.md                 # THIS FILE — wiki schema
│   ├── llm-wiki.md               # Original pattern document (reference only)
│   ├── schemas/                  # JSON Schema for frontmatter
│   ├── scripts/                  # Health check, QMD setup, CI pipelines
│   └── .markdownlint.yaml        # Markdown linting rules
├── wiki.config.yml               # Project-specific configuration
├── qmd.yml                       # QMD search engine configuration
├── package.json                  # Local remark dependencies
├── index.md                      # Content-oriented catalog of all wiki pages
├── log.md                        # Chronological append-only activity log
├── raw/                          # Raw source documents (IMMUTABLE — never modify)
│   └── .gitkeep
└── wiki/                         # All wiki pages organized by entity type
    ├── entities/                 # Specific technologies and products
    ├── concepts/                 # Architectural patterns and design principles
    ├── guides/                   # Step-by-step procedures
    └── reference/                # Catalogs, comparisons, lookup tables
```

The `.llm-wiki/` submodule provides linting, testing, and tooling shared across all wiki instances. Instance-specific content lives outside the submodule.

## Three Layers

1. **Raw sources** (`raw/`) — Immutable source documents. You read from them but NEVER modify, move, or delete them. This is the source of truth.
2. **The wiki** (`wiki/`) — LLM-generated markdown pages organized by entity type. You own this layer entirely.
3. **The schema** (`AGENTS.md` + `wiki.config.yml`) — Tells you how the wiki is structured and what workflows to follow.

## Entity Types (Directory Structure)

Pages are organized by **what kind of knowledge** they represent. Each directory maps to a distinct search intent:

| Directory | Type | Search Intent | Classification Rule |
|-----------|------|--------------|-------------------|
| `entities/` | `entity` | "What is X?" — searched by name | Has a GitHub repo, version number, or is a specific product/technology |
| `concepts/` | `concept` | "How does X work?" — searched by description | Cross-cutting idea, pattern, or architectural principle connecting entities |
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

Dense keyword-rich summary paragraph (2-3 sentences). This becomes the first
and most important qmd chunk. Include primary search terms and synonyms.

## Section Title

Body content with [[wikilinks]] to other wiki pages.

## See Also

- [[related-page-1]] — Brief description
- [[related-page-2]] — Brief description
```

### Frontmatter Rules

- `title` — Specific and descriptive (e.g., "Cilium CNI and eBPF Data Plane", not "Cilium"). This is embedded with every qmd chunk. Required.
- `type` — One of `entity`, `concept`, `guide`, `reference`. Must match the directory the file is in. Required.
- `created` — Date first created (YYYY-MM-DD). Required. Never change after creation.
- `updated` — Date of last meaningful content update (YYYY-MM-DD). Required. Update on every modification.
- `sources` — Array of filenames from `raw/` that contributed. Empty array if none. Required.
- `tags` — Array of 2-7 lowercase tags (pattern: `^[a-z0-9][a-z0-9-]*$`). First tag must match the type (`entity`, `concept`, etc.). Required.

### Body Rules (QMD-Optimized)

These rules ensure every page produces optimal qmd search chunks:

- **Title rule**: `# Title` must be specific and descriptive — it becomes the embedding prefix for every chunk. "Cilium CNI and eBPF Data Plane" not "Cilium".
- **Summary rule**: First paragraph after `# Title` must be a dense 2-3 sentence summary containing primary keywords and search terms. This becomes the first chunk.
- **Section rule**: Each `## Section` should be 200-900 tokens. If a section exceeds 900 tokens, split into its own page or add `###` subsections. `##` headings are qmd chunk boundaries (score 90).
- **Section heading rule**: `## Section` headings should be descriptive — "eBPF Data Plane" not "Overview". Section headings are chunk boundaries.
- **Cross-reference rule**: Include context with wikilinks — "See [[cilium]] for Cilium CNI eBPF configuration" not just "See [[cilium]]". Extra text is indexed by BM25.
- **Tag rule**: Include 3-7 tags covering topic, search terms, and related concepts. Tags are indexed by FTS5.
- **See Also rule**: Every page ends with `## See Also` linking to at least 2 related pages.
- **Never use `#` headings** in body (reserved for title).
- **Never use markdown links** for internal references — always use `[[wikilinks]]`.
- **Keep language concise and factual** — reference material, not prose.

## Naming Conventions

- File names: lowercase, hyphen-separated, `.md` extension (e.g., `talos-linux.md`, `edge-computing.md`).
- **Unique filenames required** — no two files in `wiki/` may share a name, regardless of directory. This enables filename-only wikilinks.
- Names should be descriptive nouns or noun-phrases that work as wikilink targets.
- Entity pages use the technology name (e.g., `cilium.md`, `flux-cd.md`).
- Concept pages use descriptive nouns (e.g., `edge-computing.md`, `networking.md`).
- Guide pages use gerund or noun forms (e.g., `deployment.md`, `ci-cd.md`).
- Never use spaces, uppercase, or special characters.

## Cross-Referencing Rules

1. **Always use `[[wikilinks]]`** — filename only, no path, no extension: `[[cilium]]` not `[[connectivity/cilium.md]]`.
2. **When creating a new page**, scan all existing pages and add wikilinks where relevant.
3. **When updating a page**, check if new content mentions concepts with their own pages and add wikilinks.
4. **Every page must have `## See Also`** with at least 2 related pages.
5. **Bidirectional linking**: if page A links to B, B should link back to A in `## See Also`.
6. **Hub pages** (like `architecture.md`, `security.md`) should link to many detail pages. Detail pages link back.
7. **Pipe wikilinks in tables**: avoid `[[page|display text]]` inside markdown tables — the `|` conflicts with column delimiters. Use plain wikilinks or restructure.

## Workflow: Ingest

When the human provides a new source document:

1. **Save the source** to `raw/` with a descriptive filename (e.g., `YYYY-MM-DD-descriptive-name.md`). NEVER modify files in `raw/` after saving.
2. **Read the source** thoroughly. Extract key information, entities, concepts, claims.
3. **Discuss with the human** (optional but preferred): summarize takeaways, confirm emphasis.
4. **Update existing pages**: scan wiki for pages that should be updated. Update content, add wikilinks, note contradictions. Update `updated` date and add source to `sources` array.
5. **Create new pages** if the source introduces topics not yet covered. Determine the entity type (entity/concept/guide/reference) and place in the correct directory. Follow page format exactly.
6. **Update `index.md`**: add new pages, update modified page summaries.
7. **Append to `log.md`**: add an entry documenting the ingest.

A single source may touch 10-15 wiki pages. This is expected and correct.

### Ingest Checklist

- [ ] Source saved to `raw/` (if not already there)
- [ ] All relevant wiki pages updated with new information
- [ ] All relevant wiki pages have the source in `sources` frontmatter
- [ ] All relevant wiki pages have updated `updated` date
- [ ] New pages created for any new topics (correct entity type directory)
- [ ] Wikilinks added from existing pages to any new pages
- [ ] `index.md` updated
- [ ] `log.md` appended with ingest entry

## Workflow: Query

When the human asks a question:

1. **Use qmd to search** — run `qmd query "question" --json -n 10` to find relevant pages.
2. **Read relevant wiki pages** in full.
3. **Synthesize an answer** with citations (mention which wiki pages contributed).
4. **If the answer is substantial**, offer to create it as a new wiki page. Good answers compound in the knowledge base.
5. **If you create a new page**, follow the full page format, update `index.md`, append to `log.md`.

### Query Page Creation

When a query result becomes a new page:

- Determine the entity type and place in the correct directory.
- Tag it with `query-derived` in addition to its type tag.
- List any raw sources in `sources` frontmatter.
- Cross-reference thoroughly with existing pages.

## Workflow: Lint

Periodically health-check the wiki:

1. **Run native linters**: `markdownlint-cli2`, `mdlint --vault wiki/`, `npx remark wiki/ --frail`
2. **Run wiki health check**: `python3 .llm-wiki/scripts/wiki-health.py wiki/`
3. **Run `qmd status`**: verify index health.
4. **Contradictions**: scan pages for conflicting claims. Flag and propose resolutions.
5. **Missing pages**: find concepts mentioned but lacking their own page.
6. **Missing cross-references**: find topics with pages but no wikilinks.

After a lint pass, append a summary to `log.md`.

## Tooling Reference

### Native Validation Tools

| Tool | Purpose | Install |
|------|---------|---------|
| markdownlint-cli2 | Markdown formatting rules | `npm install -g markdownlint-cli2` |
| mdlint-obsidian | Obsidian wikilinks, frontmatter, embeds (22 rules) | `pip install mdlint-obsidian` |
| remark-lint-frontmatter-schema | Frontmatter validation against JSON Schema | `npm ci` (local devDependencies) |
| qmd | Local search engine (BM25 + vector + reranking) | `npm install -g @tobilu/qmd` |

### Pre-Commit Hooks

Runs on every commit: markdownlint → mdlint-obsidian → remark frontmatter schema → unique filenames → raw/ protection. Configured via `.pre-commit-config.yaml` (symlinked from `.llm-wiki/`).

### CI Pipeline

The instance CI workflow (`.github/workflows/wiki-ci.yml`) calls the module's reusable GitHub Actions workflows:

1. **lint** — `uses: tibrezus/llm-wiki/.github/workflows/lint.yml@main` — consistency check → config validation → markdownlint → mdlint-obsidian → remark → unique filenames → raw/ immutability → wiki-health.py
2. **index** — `uses: tibrezus/llm-wiki/.github/workflows/index.yml@main` — qmd setup → update → embed → status → search test

The reusable workflows live in the module repo and are always fetched from `@main`. This means updating the CI pipeline across all instances is done by updating the module — instances never need to edit their CI workflow. The consistency check (`ci-consistency.sh`) detects instances that need to re-run bootstrap to sync generated files.

CI runner and Node.js version are configured in `wiki.config.yml` and passed as inputs to the reusable workflows.

## File: index.md

Content-oriented catalog. Organized by entity type. Every wiki page must be listed. Update on every ingest or page creation.

## File: log.md

Chronological append-only log. Use format:

```markdown
## [YYYY-MM-DD] operation | Short Title

- **Operation**: ingest | query | lint | create | update
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
- **Never add comments to code** unless explicitly asked
- **Never place a page in the wrong entity type directory**
