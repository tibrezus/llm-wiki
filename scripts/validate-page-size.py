#!/usr/bin/env python3
"""Enforce a deterministic per-page line limit across wiki/.

The wiki's value is that each page can be absorbed with minimal context.
This check keeps pages that way: any wiki/ page over the line limit emits an
actionable CI annotation nudging the agent to shrink or split it.

Default behaviour is a WARNING (CI stays green). Set ``pages.size_strict: true``
in wiki.config.yml (or pass --strict) to FAIL the run instead.

wiki.config.yml::

    pages:
      size_limit: 400     # int - max lines per wiki/ page (default 400)
      size_strict: false  # bool - fail CI when over (default false = warn)

Exit codes: 0 = no over-limit pages, or over-limit in warning mode;
            1 = over-limit page(s) in strict mode; 2 = bad invocation.
"""
from __future__ import annotations

import argparse
import os
import sys

DEFAULT_LIMIT = 400


def load_config(path):
    """Return (limit, strict) from wiki.config.yml, or defaults if absent/invalid."""
    limit, strict = DEFAULT_LIMIT, False
    if not path or not os.path.isfile(path):
        return limit, strict
    try:
        import yaml

        with open(path) as f:
            cfg = yaml.safe_load(f) or {}
        pages = cfg.get("pages") or {}
        if pages.get("size_limit") is not None:
            limit = int(pages["size_limit"])
        if pages.get("size_strict") is not None:
            strict = bool(pages["size_strict"])
    except Exception:
        pass  # config is optional; fall back to defaults
    return limit, strict


def iter_pages(wiki_dir):
    for root, _dirs, files in os.walk(wiki_dir):
        for name in sorted(files):
            if name.endswith(".md"):
                yield os.path.join(root, name)


def count_lines(path):
    """Line count matching `wc -l` (newline characters)."""
    with open(path, "rb") as f:
        return f.read().count(b"\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Per-page line limit for wiki/.")
    ap.add_argument("wiki_dir", help="wiki/ directory to scan")
    ap.add_argument(
        "config",
        nargs="?",
        default=None,
        help="optional wiki.config.yml for pages.size_limit / size_strict",
    )
    ap.add_argument("--limit", type=int, default=None, help="override the line limit")
    ap.add_argument("--strict", action="store_true", help="fail (exit 1) on over-limit pages")
    args = ap.parse_args(argv)

    limit, strict = load_config(args.config)
    if args.limit is not None:
        limit = args.limit
    if args.strict:
        strict = True
    if limit < 1:
        limit = DEFAULT_LIMIT

    if not os.path.isdir(args.wiki_dir):
        print(f"::error::wiki dir not found: {args.wiki_dir}", file=sys.stderr)
        return 2

    over = []
    for page in iter_pages(args.wiki_dir):
        n = count_lines(page)
        if n > limit:
            over.append((page, n))

    def rel(p):
        return os.path.relpath(p)

    for page, n in over:
        ann = "error" if strict else "warning"
        msg = (
            f"{n} lines > {limit} limit - shrink (tighten prose, push raw detail "
            f"into raw/) or split (extract a sub-topic to its own page)."
        )
        print(f"::{ann} file={rel(page)}::{msg}")

    if over:
        kind = "FAIL" if strict else "warn"
        print(f"page-size: {len(over)} page(s) over the {limit}-line limit ({kind})")
        if strict:
            return 1
    else:
        print(f"page-size: OK (all pages within the {limit}-line limit)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
