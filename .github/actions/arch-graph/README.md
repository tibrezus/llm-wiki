# Architecture Graph Action (C4)

Generate C4 architecture diagrams from source code and push them to the
project's own wiki — **no LLM, no k8s, no PAT.** The CI's built-in token
(`GITHUB_TOKEN`, auto-provided on all platforms) already has access to the
wiki repo — it's the same project, just `<repo>.wiki.git`.

The pipeline is fully deterministic:

```
source → emit-rig.py → rig.json → rig-to-c4.py → model.c4 → likec4 gen mermaid → *.mmd → wiki pages
```

This is the same deterministic pipeline that harmostes runs in-cluster,
extracted into a single action that any project's own CI can use.

## Quick Start (GitHub)

**One prerequisite:** initialize the wiki — go to your repo → Wiki tab →
create the first page (any content). This provisions the `<repo>.wiki.git`
repository.

```yaml
# .github/workflows/arch.yml
name: Architecture Diagrams
on:
  push:
    branches: [main]

permissions:
  contents: write        # gives GITHUB_TOKEN write access to the wiki

jobs:
  arch:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: tibrezus/llm-wiki/.github/actions/arch-graph@main
        with:
          language: go          # optional: go, zig, python, rust, ...
```

No secrets to create, no tokens to manage. The `GITHUB_TOKEN` is
auto-provided by GitHub Actions and has access to the wiki repo.

## Quick Start (Codeberg / Forgejo)

Same principle — the CI token already has wiki access. Use a manual
workflow since Codeberg/Forgejo runners can't reference GitHub actions
directly:

```yaml
# .forgejo/workflows/arch.yml  (Codeberg)
name: Architecture Diagrams
on:
  push:
    branches: [main]

permissions:
  contents: write

jobs:
  arch:
    runs-on: ubuntu-latest
    steps:
      - uses: https://code.forgejo.org/actions/checkout@v4

      - name: Generate C4 diagrams
        run: |
          git clone --depth 1 --filter=blob:none --sparse \
            https://github.com/tibrezus/llm-wiki.git /tmp/tools
          cd /tmp/tools && git sparse-checkout set .github/actions/repo-map
          npm install -g likec4
          bash /tmp/tools/.github/actions/repo-map/arch-graph.sh \
            --tools-dir /tmp/tools/.github/actions/repo-map \
            --output-dir arch-out

      - name: Push to wiki
        run: |
          bash /tmp/tools/.github/actions/repo-map/push-to-wiki.sh arch-out/wiki
```

> **git.rezus.cloud runners** that can't reach GitHub: point the tools
> clone at the Forgejo mirror:
> `https://git.rezus.cloud/tibrez/llm-wiki-template.git`

## What it produces

The wiki gets:

| File | Content |
|------|---------|
| `Architecture.md` | System Context + Container diagrams (Mermaid, renders natively) |
| `Components/<name>.md` | One page per component view, linked from Architecture.md |

Each page embeds a ```mermaid code block that renders natively on GitHub,
Codeberg, and Forgejo wikis.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `language` | no | `""` (auto-detect) | Language hint: go, zig, python, rust, ... |
| `commit-message` | no | `"Update architecture diagrams [skip ci]"` | Wiki commit message |
| `tools-version` | no | `main` | llm-wiki module ref (pin for reproducibility) |

## How it works

1. **RIG generation** — `emit-rig.py` auto-detects the build system
   (Go modules, Zig build.zig, Cargo, npm, CMake, Python) and produces a
   Repository Intelligence Graph (RIG) JSON. Components are build targets;
   evidence is build-system-backed.
2. **C4 model generation** — `rig-to-c4.py` derives a LikeC4 `model.c4`
   from the RIG, extracting doc comments (`//`, `//!`, `/* */`, docstrings)
   and exported API surface (function/type signatures) from source files.
3. **Mermaid export** — `likec4 gen mermaid --use-dot` converts each C4 view
   into a standalone `.mmd` diagram.
4. **Wiki page assembly** — `build-wiki-pages.py` wraps the Mermaid in
   markdown pages that render natively.

No LLM is involved. The output is deterministic: the same source always
produces the same diagrams.

## Docker/CI requirements

When running inside Docker containers (Forgejo/GitHub Actions runners):

- **Node.js >= 22** — likec4 requires Node 22+. If your CI image ships an
  older version, upgrade in-container: `npm install -g n && n 22`
- **graphviz** — likec4's WASM layout engine crashes inside Docker containers.
  Install graphviz (`apt-get install -y graphviz`) and the script automatically
  uses `--use-dot` as the layout engine, falling back to WASM if dot is absent.
