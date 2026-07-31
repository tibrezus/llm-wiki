#!/usr/bin/env python3
"""build-wiki-pages.py — Convert likec4 .mmd files + RIG into wiki markdown.

Generates:
  Architecture.md          — structure diagram + source map + component links
  Component---<name>.md    — one flat page per component view (no subdirs —
                             Forgejo wiki 500-errors on subdirectory paths)

Also copies raw artifacts (rig.json, model.c4) if they exist alongside the
.mmd files, so the wiki is self-contained.

Usage:
    build-wiki-pages.py <mmd-dir> [--output-dir <dir>] [--project-name <name>]
    [--rig-file <rig.json>]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def parse_mmd(path: Path) -> tuple[str | None, str]:
    """Parse a .mmd file, returning (title, mermaid_body)."""
    text = path.read_text(encoding="utf-8")
    title: str | None = None
    body = text

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
    name = title.split(" — ")[0].split(" - ")[0]
    name = re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-").lower()
    return name or "diagram"


def sanitize_mermaid_id(name: str) -> str:
    """Make a string safe for use as a Mermaid node/subgraph ID."""
    return re.sub(r"[^A-Za-z0-9_]", "_", name)


def build_source_map(rig_path: Path, max_files_per_component: int = 50) -> str | None:
    """Generate a Mermaid diagram from the RIG showing ALL source files
    grouped by build-target component.

    This is the 'complete repository structure' — every source file visible
    in one graph, organized by component. likec4's system-level view only
    shows build targets; this goes deeper.
    """
    try:
        rig = json.loads(rig_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None

    components = rig.get("components", [])
    if not components:
        return None

    lines: list[str] = ["graph TB"]
    used_ids: set[str] = set()

    def unique_id(name: str) -> str:
        base = sanitize_mermaid_id(name)
        sid = base
        i = 2
        while sid in used_ids:
            sid = f"{base}{i}"
            i += 1
        used_ids.add(sid)
        return sid

    for comp in components:
        comp_name = comp.get("name", comp.get("id", "unknown"))
        comp_type = comp.get("type", "")
        comp_id = unique_id(f"comp_{comp_name}")
        label = f'{comp_name} ({comp_type})' if comp_type else comp_name

        srcs = comp.get("source_files", [])
        if not srcs:
            # Component with no source files — just a box
            lines.append(f'  {comp_id}["`{label}`"]')
            continue

        # Subgraph for this component's source files
        lines.append(f'  subgraph {comp_id}["`{label}`"]')

        shown = 0
        skipped = len(srcs) - max_files_per_component
        for sf in srcs[:max_files_per_component]:
            sf_name = Path(sf).name
            sf_id = unique_id(f"{comp_id}_{sf_name}")
            lines.append(f'    {sf_id}["`{sf_name}`"]')
            shown += 1

        if skipped > 0:
            lines.append(f'    {comp_id}_more["`... +{skipped} more files`"]')

        lines.append("  end")

    # Add dependency edges between components
    deps = rig.get("dependencies", [])
    comp_name_to_id: dict[str, str] = {}
    for comp in components:
        cname = comp.get("name", comp.get("id", ""))
        for line_idx, line in enumerate(lines):
            if line.strip().startswith(f"subgraph {sanitize_mermaid_id(f'comp_{cname}')}"):
                comp_name_to_id[comp.get("id", cname)] = sanitize_mermaid_id(f"comp_{cname}")
                break

    for dep in deps:
        src_id = comp_name_to_id.get(dep.get("from_id") or dep.get("source_id", ""))
        tgt_id = comp_name_to_id.get(dep.get("to_id") or dep.get("target_id", ""))
        if src_id and tgt_id:
            dep_type = dep.get("type", "depends on")
            lines.append(f'  {src_id} -. "`{dep_type}`" .-> {tgt_id}')

    return "\n".join(lines) if len(lines) > 1 else None


def build_pages(
    mmd_dir: Path,
    output_dir: Path,
    project_name: str,
    rig_path: Path | None = None,
) -> list[Path]:
    """Build wiki pages from .mmd files + RIG. Returns generated file paths."""
    mmd_files = sorted(mmd_dir.glob("*.mmd"))

    structure_body: str | None = None
    context_body: str | None = None
    container_body: str | None = None
    component_pages: list[tuple[str, str, str]] = []  # (slug, title, body)
    index_count = 0

    for mmd in mmd_files:
        title, body = parse_mmd(mmd)
        if mmd.stem == "index":
            index_count += 1
            continue

        stem = mmd.stem.lower()
        tl = (title or "").lower()
        if stem == "structure" or "repository structure" in tl:
            structure_body = body
        elif stem == "context" or "context" in tl:
            context_body = body
        elif stem == "containers" or "containers" in tl:
            container_body = body
        else:
            component_pages.append((slugify(title or mmd.stem), title or mmd.stem, body))

    # Generate source map from RIG if available
    source_map: str | None = None
    if rig_path and rig_path.exists():
        source_map = build_source_map(rig_path)

    output_dir.mkdir(parents=True, exist_ok=True)
    generated: list[Path] = []

    # ── Main Architecture.md page ────────────────────────────────────
    arch_lines: list[str] = [
        f"# Architecture — {project_name}",
        "",
        "> Auto-generated from source code analysis. "
        "Regenerated on every push to `main`.",
        "",
    ]

    # Structure / context / container view
    if structure_body:
        arch_lines += ["## Repository Structure", "", "```mermaid", structure_body, "```", ""]
    else:
        if context_body:
            arch_lines += ["## System Context", "", "```mermaid", context_body, "```", ""]
        if container_body and container_body != context_body:
            arch_lines += ["## Containers", "", "```mermaid", container_body, "```", ""]

    # Source map — the complete file-level structure (the "detail" view)
    if source_map:
        arch_lines += [
            "## Source Files",
            "",
            "Every source file in the repository, grouped by build target:",
            "",
            "```mermaid",
            source_map,
            "```",
            "",
        ]

    # Component detail pages — flat names (no subdirectory — Forgejo 500s)
    if component_pages:
        arch_lines += [
            "## Component Details",
            "",
            "| Component | Diagram |",
            "|---|---|",
        ]
        for slug, title, body in component_pages:
            page_name = f"Component---{slug}.md"
            display = title.split(" — ")[0] if " — " in title else title
            arch_lines.append(f"| {display} | [{slug}]({page_name.replace('.md', '')}) |")

            # Write flat page (no subdirectory)
            comp_page = output_dir / page_name
            comp_page.write_text(
                f"# {title}\n\n"
                f"← [Back to Architecture](Architecture)\n\n"
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
        + (f" + {len(component_pages)} component pages" if component_pages else "")
        + (f" + source map ({len(mmd_files)} .mmd, {index_count} index skipped)" if source_map else "")
    )
    return generated


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert likec4 .mmd diagrams + RIG into wiki markdown pages."
    )
    parser.add_argument("mmd_dir", type=Path, help="Directory containing .mmd files")
    parser.add_argument("--output-dir", type=Path, default=Path("wiki-out"))
    parser.add_argument("--project-name", default="Project")
    parser.add_argument("--rig-file", type=Path, default=None, help="RIG JSON for source map")
    args = parser.parse_args()

    if not args.mmd_dir.is_dir():
        print(f"Error: {args.mmd_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    pages = build_pages(args.mmd_dir, args.output_dir, args.project_name, args.rig_file)
    if not pages:
        sys.exit(1)


if __name__ == "__main__":
    main()
