#!/usr/bin/env python3
"""Wiki health check — structural validation beyond what native linters cover.

Checks:
  - Orphan pages (no inbound wikilinks)
  - index.md accuracy (matches actual wiki pages)
  - Bidirectional See Also verification
  - Unique filenames across wiki/
  - Stale pages (not updated in 90+ days)
  - Missing See Also sections
  - Type/directory mismatch (file type doesn't match directory)
"""

import sys
import os
import re
import yaml
from pathlib import Path
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from collections import defaultdict


@dataclass
class WikiPage:
    name: str
    path: Path
    frontmatter: dict | None
    wikilinks: list[str]
    content: str


def parse_frontmatter(content: str) -> dict | None:
    match = re.match(r"^---\n(.*?)\n---", content, re.DOTALL)
    if not match:
        return None
    try:
        return yaml.safe_load(match.group(1))
    except yaml.YAMLError:
        return None


def extract_wikilinks(content: str) -> list[str]:
    return re.findall(r"\[\[([^\]|#]+)(?:[#|][^\]]*)?\]\]", content)


def parse_all(wiki_root: str) -> dict[str, WikiPage]:
    pages: dict[str, WikiPage] = {}
    for md in Path(wiki_root).rglob("*.md"):
        name = md.stem
        content = md.read_text(encoding="utf-8")
        pages[name] = WikiPage(
            name=name,
            path=md,
            frontmatter=parse_frontmatter(content),
            wikilinks=extract_wikilinks(content),
            content=content,
        )
    return pages


def check_unique_names(pages: dict[str, WikiPage]) -> list[str]:
    errors = []
    seen: dict[str, list[Path]] = defaultdict(list)
    for page in pages.values():
        seen[page.name].append(page.path)
    for name, paths in seen.items():
        if len(paths) > 1:
            locs = ", ".join(str(p) for p in paths)
            errors.append(f"DUPLICATE: '{name}' exists in multiple locations: {locs}")
    return errors


def check_type_directory_match(pages: dict[str, WikiPage]) -> list[str]:
    errors = []
    type_to_dir = {"entity": "entities", "concept": "concepts", "guide": "guides", "reference": "reference"}
    for page in pages.values():
        fm = page.frontmatter
        if not fm:
            errors.append(f"NO-FRONTMATTER: {page.path}")
            continue
        page_type = fm.get("type", "")
        expected_dir = type_to_dir.get(page_type)
        if expected_dir and expected_dir not in page.path.parts:
            errors.append(f"TYPE-MISMATCH: {page.path} has type='{page_type}' but is not in {expected_dir}/")
        tags = fm.get("tags", [])
        if tags and tags[0] != page_type:
            errors.append(f"FIRST-TAG-TYPE: {page.path} first tag is '{tags[0]}' but type is '{page_type}'")
    return errors


def check_broken_wikilinks(pages: dict[str, WikiPage]) -> list[str]:
    all_names = set(pages.keys())
    errors = []
    for page in pages.values():
        for link in page.wikilinks:
            if link not in all_names:
                errors.append(f"BROKEN-LINK: {page.path} links to [[{link}]] which does not exist")
    return errors


def check_orphans(pages: dict[str, WikiPage]) -> list[str]:
    inbound: dict[str, int] = defaultdict(int)
    all_names = set(pages.keys())
    for page in pages.values():
        for link in page.wikilinks:
            if link in all_names:
                inbound[link] += 1
    errors = []
    for name in all_names:
        if inbound[name] == 0:
            errors.append(f"ORPHAN: [[{name}]] has no inbound wikilinks")
    return errors


def check_see_also(pages: dict[str, WikiPage]) -> list[str]:
    errors = []
    for page in pages.values():
        if "## See Also" not in page.content:
            errors.append(f"MISSING-SEE-ALSO: {page.path} has no ## See Also section")
            continue
        see_also = page.content.split("## See Also")[1]
        links = extract_wikilinks(see_also)
        if len(links) < 2:
            errors.append(f"INSUFFICIENT-SEE-ALSO: {page.path} has {len(links)} link(s) in See Also (minimum 2)")
    return errors


def check_bidirectional(pages: dict[str, WikiPage]) -> list[str]:
    warnings = []
    all_names = set(pages.keys())
    links_from: dict[str, set[str]] = defaultdict(set)
    for page in pages.values():
        for link in page.wikilinks:
            if link in all_names:
                links_from[page.name].add(link)
    for name, targets in links_from.items():
        for target in targets:
            if name not in links_from.get(target, set()):
                warnings.append(f"UNIDIRECTIONAL: [[{name}]] -> [[{target}]] but no link back")
    return warnings


def check_no_body_h1(pages: dict[str, WikiPage]) -> list[str]:
    """Check that no page uses # headings after the title line."""
    errors = []
    for page in pages.values():
        lines = page.content.split("\n")
        in_frontmatter = False
        frontmatter_done = False
        h1_count = 0
        for line in lines:
            if line.strip() == "---" and not frontmatter_done:
                if not in_frontmatter:
                    in_frontmatter = True
                    continue
                else:
                    in_frontmatter = False
                    frontmatter_done = True
                    continue
            if in_frontmatter:
                continue
            if line.startswith("# "):
                h1_count += 1
                if h1_count > 1:
                    errors.append(f"BODY-H1: {page.path} has multiple # headings (reserved for title)")
                    break
    return errors


def check_summary_paragraph(pages: dict[str, WikiPage]) -> list[str]:
    """Check that the first content after # Title is a paragraph, not a section."""
    errors = []
    for page in pages.values():
        lines = page.content.split("\n")
        in_frontmatter = False
        frontmatter_done = False
        found_title = False
        for line in lines:
            stripped = line.strip()
            if stripped == "---" and not frontmatter_done:
                if not in_frontmatter:
                    in_frontmatter = True
                    continue
                else:
                    in_frontmatter = False
                    frontmatter_done = True
                    continue
            if in_frontmatter:
                continue
            if not found_title and stripped.startswith("# "):
                found_title = True
                continue
            if found_title and stripped == "":
                continue
            if found_title:
                if stripped.startswith("## "):
                    errors.append(f"NO-SUMMARY: {page.path} jumps from title to ## section without a summary paragraph")
                break
    return errors


def check_sources_exist(pages: dict[str, WikiPage], wiki_root: str) -> list[str]:
    """Check that all source references in frontmatter point to files in raw/."""
    errors = []
    raw_dir = Path(wiki_root).parent / "raw"
    for page in pages.values():
        fm = page.frontmatter
        if not fm:
            continue
        sources = fm.get("sources", [])
        if not sources:
            continue
        for source in sources:
            if not (raw_dir / source).exists():
                errors.append(f"MISSING-SOURCE: {page.path} references '{source}' but it does not exist in raw/")
    return errors


def check_markdown_links(pages: dict[str, WikiPage]) -> list[str]:
    """Check that internal references use [[wikilinks]] not markdown links."""
    errors = []
    for page in pages.values():
        lines = page.content.split("\n")
        in_frontmatter = False
        frontmatter_done = False
        for i, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped == "---" and not frontmatter_done:
                if not in_frontmatter:
                    in_frontmatter = True
                    continue
                else:
                    in_frontmatter = False
                    frontmatter_done = True
                    continue
            if in_frontmatter:
                continue
            # Match [text](path) where path is not external
            for m in re.finditer(r'\[([^\]]*?)\]\((?!https?://|mailto:|#)([^)]*?)\)', line):
                errors.append(f"MD-LINK: {page.path}:{i} uses markdown link [{m.group(1)}]({m.group(2)}) instead of [[wikilink]]")
    return errors


def check_log_format(wiki_root: str) -> list[str]:
    """Check that log.md entries follow the required format."""
    errors = []
    log_path = Path(wiki_root).parent / "log.md"
    if not log_path.exists():
        errors.append("MISSING-LOG: log.md does not exist")
        return errors
    content = log_path.read_text(encoding="utf-8")
    entries = re.findall(r"^## \[(\d{4}-\d{2}-\d{2})\] (.+)$", content, re.MULTILINE)
    if not entries:
        errors.append("LOG-FORMAT: log.md has no valid entries (expected format: ## [YYYY-MM-DD] operation | Title)")
    for date_str, title in entries:
        if " | " not in title:
            errors.append(f"LOG-FORMAT: log.md entry '[{date_str}] {title}' missing operation type (expected: '## [{date_str}] operation | Title')")
    return errors


def check_see_also_links_valid(pages: dict[str, WikiPage]) -> list[str]:
    """Check that all wikilinks in See Also sections resolve to existing pages."""
    errors = []
    all_names = set(pages.keys())
    for page in pages.values():
        if "## See Also" not in page.content:
            continue
        see_also = page.content.split("## See Also")[1]
        links = extract_wikilinks(see_also)
        for link in links:
            if link not in all_names:
                errors.append(f"BROKEN-SEE-ALSO: {page.path} See Also links to [[{link}]] which does not exist")
    return errors


def check_stale(pages: dict[str, WikiPage], days: int = 90) -> list[str]:
    warnings = []
    cutoff = datetime.now() - timedelta(days=days)
    for page in pages.values():
        fm = page.frontmatter
        if not fm:
            continue
        updated = fm.get("updated", "")
        if not updated:
            continue
        try:
            if isinstance(updated, datetime):
                updated_date = updated
            elif isinstance(updated, date):
                updated_date = datetime(updated.year, updated.month, updated.day)
            else:
                updated_date = datetime.strptime(str(updated), "%Y-%m-%d")
            if updated_date < cutoff:
                warnings.append(f"STALE: {page.path} not updated since {updated} ({(datetime.now() - updated_date).days} days)")
        except ValueError:
            pass
    return warnings


def check_index(pages: dict[str, WikiPage], wiki_root: str) -> list[str]:
    errors = []
    index_path = Path(wiki_root).parent / "index.md"
    if not index_path.exists():
        errors.append("MISSING-INDEX: index.md does not exist")
        return errors
    index_content = index_path.read_text(encoding="utf-8")
    index_links = set(extract_wikilinks(index_content))
    wiki_names = set(pages.keys())
    missing_from_index = wiki_names - index_links
    for name in missing_from_index:
        errors.append(f"MISSING-FROM-INDEX: [[{name}]] exists in wiki but not in index.md")
    extra_in_index = index_links - wiki_names
    for name in extra_in_index:
        errors.append(f"EXTRA-IN-INDEX: index.md links to [[{name}]] but no wiki page exists")
    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: wiki-health.py <wiki-root>")
        sys.exit(1)

    wiki_root = sys.argv[1]
    if not os.path.isdir(wiki_root):
        print(f"Error: {wiki_root} is not a directory")
        sys.exit(1)

    pages = parse_all(wiki_root)
    all_errors = []
    all_warnings = []

    print(f"=== Wiki Health Check ({len(pages)} pages) ===\n")

    checks = [
        ("Unique filenames", check_unique_names, True),
        ("Type/directory match", check_type_directory_match, True),
        ("Broken wikilinks", check_broken_wikilinks, True),
        ("See Also link validity", check_see_also_links_valid, True),
        ("No body H1 headings", check_no_body_h1, True),
        ("Summary paragraph", check_summary_paragraph, True),
        ("Sources exist in raw/", lambda p: check_sources_exist(p, wiki_root), True),
        ("No markdown links", check_markdown_links, True),
        ("Log format", lambda p: check_log_format(wiki_root), True),
        ("Orphan pages", check_orphans, False),
        ("See Also sections", check_see_also, True),
        ("Bidirectional links", check_bidirectional, False),
        ("Stale pages", lambda p: check_stale(p, 90), False),
        ("Index accuracy", lambda p: check_index(p, wiki_root), False),
    ]

    for name, check_fn, is_error in checks:
        results = check_fn(pages)
        if results:
            for r in results:
                if is_error:
                    all_errors.append(r)
                else:
                    all_warnings.append(r)
            status = "FAIL" if is_error else "WARN"
            print(f"\n[{status}] {name}:")
            for r in results:
                print(f"  {r}")
        else:
            print(f"[OK] {name}")

    print(f"\n=== Summary ===")
    print(f"Errors: {len(all_errors)}")
    print(f"Warnings: {len(all_warnings)}")

    if all_errors:
        print("\nHealth check FAILED — fix errors before merging.")
        sys.exit(1)
    else:
        print("\nHealth check PASSED.")
        sys.exit(0)


if __name__ == "__main__":
    main()
