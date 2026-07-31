# Architecture Graph Action (C4)

Generate C4 architecture diagrams from source code and push them to the
project's own wiki — **no LLM, no k8s, no external infrastructure.**

The pipeline is fully deterministic:

```
source → emit-rig.py → rig.json → rig-to-c4.py → model.c4 → likec4 gen mermaid → *.mmd → wiki pages
```

This is the same deterministic pipeline that harmostes runs in-cluster,
extracted into a single action that any project's own CI can use.

## Quick Start (GitHub)

1. **Initialize the wiki** — go to your repo → Wiki tab → create the first
   page (any content). This provisions the `<repo>.wiki.git` repository.

2. **Create a token** — GitHub → Settings → Developer settings → Personal
   access tokens → fine-grained tokens → create one with **Contents: Read
   and Write** for your repo. Add it as a repository secret named
   `WIKI_TOKEN`.

3. **Add the workflow** to `.github/workflows/arch.yml`:

```yaml
name: Architecture Diagrams
on:
  push:
    branches: [main]

jobs:
  arch:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: tibrezus/llm-wiki/.github/actions/arch-graph@main
        with:
          language: go          # optional: go, zig, python, rust, ...
          wiki-token: ${{ secrets.WIKI_TOKEN }}
```

That's it. On every push to `main`, the action generates the C4 diagrams
and pushes them to your wiki. The diagrams render natively on GitHub wiki.

## Quick Start (Codeberg / Forgejo)

Codeberg/Forgejo runners can't reference GitHub actions directly. Use a
manual workflow instead:

```yaml
# .forgejo/workflows/arch.yml  (Codeberg)
# .gitea/workflows/arch.yml     (Gitea)
name: Architecture Diagrams
on:
  push:
    branches: [main]

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
          npm install -g @likec4/generator
          bash /tmp/tools/.github/actions/repo-map/arch-graph.sh \
            --tools-dir /tmp/tools/.github/actions/repo-map \
            --output-dir arch-out

      - name: Push to wiki
        env:
          WIKI_TOKEN: ${{ secrets.WIKI_TOKEN }}
        run: |
          bash /tmp/tools/.github/actions/repo-map/push-to-wiki.sh arch-out/wiki
```

For Codeberg, create a token with `write:repository` scope and add it as
the `WIKI_TOKEN` secret.

> **Private repos on git.rezus.cloud runners:** if the runner can't reach
> GitHub, point the tools clone at the Forgejo mirror:
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
| `wiki-token` | **yes** | — | Token with wiki write access |
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
3. **Mermaid export** — `likec4 gen mermaid` converts each C4 view into a
   standalone `.mmd` diagram.
4. **Wiki page assembly** — `build-wiki-pages.py` wraps the Mermaid in
   markdown pages that render natively.

No LLM is involved. The output is deterministic: the same source always
produces the same diagrams.
