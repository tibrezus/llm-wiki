#!/usr/bin/env python3
"""build-wiki-pages.py — Convert likec4-generated .mmd files into wiki markdown.

Each .mmd file is a Mermaid diagram with YAML frontmatter (title). This script
strips the frontmatter, wraps the graph in a ```mermaid code block, and
assembles all diagrams into wiki pages that render natively on GitHub wiki,
Codeberg wiki, and Forgejo wiki.

Output structure:
  <output-dir>/Architecture.md   — context + container views (the overview)
  <output-dir>/Components/<X>.md  — one page per component view (if any)

Usage:
    build-wiki-pages.py <mmd-dir> [--output-dir <dir>] [--project-name <name>]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def parse_mmd(path: Path) -> tuple[str | None, str]:
    """Parse a .mmd file, returning (title, mermaid_body).

    Strips YAML frontmatter if present. The title is extracted from the
    'title:' field; the body is the raw Mermaid graph text.
    """
    text = path.read_text(encoding="utf-8")
    title: str | None = None
    body = text

    # Strip YAML frontmatter (---\ntitle: "..."\n---)
    if body.startswith("---"):
        end = body.find("\n---", 3)
        if end != -1:
            frontmatter = body[3:end].strip()
            body = body[end + 4 :].lstrip("\n")
            m = re.search(r'^title:\s*["\']?(.+?)["\']?\s*$', frontmatter, re.MULTILINE)
            if m:
                title = m.group(1).strip().strip("'\"")

    return title, body.strip()


def slugify(title: str) -> str:
    """Convert a title to a wiki-safe filename slug."""
    # Take the part before " — " (the actual view name, not the suffix)
    name = title.split(" — ")[0].split(" - ")[0]
    name = re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-").lower()
    return name or "diagram"


def build_pages(mmd_dir: Path, output_dir: Path, project_name: str) -> list[Path]:
    """Build wiki pages from .mmd files. Returns list of generated file paths."""
    mmd_files = sorted(mmd_dir.glob("*.mmd"))
    if not mmd_files:
        print(f"[build-wiki-pages] No .mmd files found in {mmd_dir}", file=sys.stderr)
        return []

    context_body: str | None = None
    container_body: str | None = None
    component_pages: list[tuple[str, str, str]] = []  # (slug, title, body)
    index_count = 0

    for mmd in mmd_files:
        title, body = parse_mmd(mmd)

        # Skip the likec4 index file (just links to views)
        if mmd.stem == "index":
            index_count += 1
            continue

        # Classify by view type
        stem = mmd.stem.lower()
        tl = (title or "").lower()
        if stem == "context" or "context" in tl:
            context_body = body
        elif stem == "containers" or "containers" in tl:
            container_body = body
        else:
            component_pages.append((slugify(title or mmd.stem), title or mmd.stem, body))

    output_dir.mkdir(parents=True, exist_ok=True)
    generated: list[Path] = []

    # ── Main Architecture.md page ────────────────────────────────────
    arch_lines: list[str] = [
        f"# Architecture — {project_name}",
        "",
        (
            "> Auto-generated from source code analysis. "
            "Regenerated on every push to `main`."
        ),
        "",
    ]

    has_components = bool(component_pages)

    if context_body:
        arch_lines += ["## System Context", "", "```mermaid", context_body, "```", ""]
    if container_body:
        arch_lines += ["## Containers", "", "```mermaid", container_body, "```", ""]

    if has_components:
        arch_lines += [
            "## Component Views",
            "",
            "| Component | Diagram |",
            "|---|---|",
        ]
        comp_dir = output_dir / "Components"
        for slug, title, body in component_pages:
            page_name = f"Components/{slug}.md"
            arch_lines.append(f"| {title} | [{slug}]({page_name}) |")

            # Write the component page
            comp_dir.mkdir(parents=True, exist_ok=True)
            comp_page = comp_dir / f"{slug}.md"
            comp_page.write_text(
                f"# {title}\n\n"
                f"← [Back to Architecture](../Architecture.md)\n\n"
                f"```mermaid\n{body}\n```\n",
                encoding="utf-8",
            )
            generated.append(comp_page)

        arch_lines.append("")

    arch_path = output_dir / "Architecture.md"
    arch_path.write_text("\n".join(arch_lines) + "\n", encoding="utf-8")
    generated.append(arch_path)

    print(
        f"[build-wiki-pages] Generated {len(generated)} page(s): "
        f"Architecture.md"
        + (f" + {len(component_pages)} component pages" if has_components else "")
        + f" ({index_count} index skipped)"
    )
    return generated


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert likec4 .mmd diagrams into wiki markdown pages."
    )
    parser.add_argument("mmd_dir", type=Path, help="Directory containing .mmd files")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("wiki-out"),
        help="Output directory for wiki pages (default: wiki-out)",
    )
    parser.add_argument(
        "--project-name",
        default="Project",
        help="Project name for page titles (default: Project)",
    )
    args = parser.parse_args()

    if not args.mmd_dir.is_dir():
        print(f"Error: {args.mmd_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    pages = build_pages(args.mmd_dir, args.output_dir, args.project_name)
    if not pages:
        sys.exit(1)


if __name__ == "__main__":
    main()
