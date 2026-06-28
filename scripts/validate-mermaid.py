#!/usr/bin/env python3
"""Validate every ```mermaid block in wiki/ by rendering it with mmdc.

Usage: validate-mermaid.py <wiki_dir> [puppeteer_config]

Extracts each fenced mermaid block from .md files, writes it to a temp file,
and runs `mmdc` to render-check it. Exits 1 if any block fails to render.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def extract_mermaid_blocks(md_path: Path):
    """Yield (file_path, block_index, content) for each mermaid block."""
    content = md_path.read_text(encoding="utf-8", errors="replace")
    blocks = re.findall(r"```mermaid\n(.*?)```", content, re.DOTALL)
    for i, block in enumerate(blocks, 1):
        yield i, block


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <wiki_dir> [puppeteer_config]", file=sys.stderr)
        sys.exit(2)

    wiki_dir = Path(sys.argv[1])
    puppeteer_config = sys.argv[2] if len(sys.argv) > 2 else None

    if not wiki_dir.is_dir():
        print(f"Error: {wiki_dir} is not a directory", file=sys.stderr)
        sys.exit(2)

    md_files = sorted(wiki_dir.rglob("*.md"))
    total = 0
    failed = 0

    with tempfile.TemporaryDirectory() as tmpdir:
        out_svg = Path(tmpdir) / "out.svg"
        block_file = Path(tmpdir) / "block.mmd"

        for md_path in md_files:
            for idx, block in extract_mermaid_blocks(md_path):
                total += 1
                block_file.write_text(block)
                cmd = [
                    "npx", "mmdc",
                    "-i", str(block_file),
                    "-o", str(out_svg),
                    "--quiet",
                ]
                if puppeteer_config:
                    cmd.extend(["-p", puppeteer_config])
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                if result.returncode != 0:
                    failed += 1
                    rel = md_path.relative_to(wiki_dir.parent) if md_path.parent != wiki_dir.parent else md_path
                    print(f"  FAIL: {rel} (block {idx})", file=sys.stderr)
                    # Show first line of stderr for debugging
                    err_line = result.stderr.strip().split("\n")[0] if result.stderr.strip() else "unknown error"
                    print(f"        {err_line}", file=sys.stderr)

    if failed > 0:
        print(f"\n{failed}/{total} mermaid blocks failed to render", file=sys.stderr)
        sys.exit(1)

    print(f"OK ({total} mermaid block(s) validated)")
    sys.exit(0)


if __name__ == "__main__":
    main()
