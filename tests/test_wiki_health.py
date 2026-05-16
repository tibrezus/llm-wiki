#!/usr/bin/env python3
"""Tests for wiki-health.py check functions.

Run: python3 -m pytest tests/test_wiki_health.py -v
  or: python3 -m unittest tests.test_wiki_health -v
"""

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.parent / "scripts"
spec = importlib.util.spec_from_file_location("wiki_health", SCRIPT_DIR / "wiki-health.py")
wiki_health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wiki_health)

WikiPage = wiki_health.WikiPage
parse_all = wiki_health.parse_all
check_unique_names = wiki_health.check_unique_names
check_type_directory_match = wiki_health.check_type_directory_match
check_broken_wikilinks = wiki_health.check_broken_wikilinks
check_orphans = wiki_health.check_orphans
check_see_also = wiki_health.check_see_also
check_bidirectional = wiki_health.check_bidirectional
check_stale = wiki_health.check_stale
check_index = wiki_health.check_index


def make_page(name, path, frontmatter=None, wikilinks=None, content=""):
    return WikiPage(
        name=name,
        path=Path(path),
        frontmatter=frontmatter,
        wikilinks=wikilinks or [],
        content=content,
    )


def make_entity_page(name, updated="2026-01-15", wikilinks=None):
    content = f"""---
title: {name.title()}
type: entity
created: 2026-01-15
updated: {updated}
sources: []
tags: [entity, test]
---

# {name.title()}

Summary paragraph.

## See Also

- [[other]] — desc
- [[another]] — desc
"""
    return make_page(
        name=name,
        path=f"wiki/entities/{name}.md",
        frontmatter={"title": f"{name.title()}", "type": "entity", "created": "2026-01-15", "updated": updated, "sources": [], "tags": ["entity", "test"]},
        wikilinks=wikilinks or ["other", "another"],
        content=content,
    )


class TestUniqueNames(unittest.TestCase):
    def test_no_duplicates(self):
        pages = {
            "alpha": make_page("alpha", "wiki/entities/alpha.md"),
            "beta": make_page("beta", "wiki/concepts/beta.md"),
        }
        self.assertEqual(check_unique_names(pages), [])

    def test_duplicates(self):
        pages = {
            "alpha": make_page("alpha", "wiki/entities/alpha.md"),
            "alpha2": make_page("alpha", "wiki/concepts/alpha.md"),
        }
        errors = check_unique_names(pages)
        self.assertEqual(len(errors), 1)
        self.assertIn("DUPLICATE", errors[0])


class TestTypeDirectoryMatch(unittest.TestCase):
    def test_correct_match(self):
        pages = {"cilium": make_page("cilium", "wiki/entities/cilium.md", frontmatter={"type": "entity", "tags": ["entity"]})}
        self.assertEqual(check_type_directory_match(pages), [])

    def test_type_mismatch(self):
        pages = {"cilium": make_page("cilium", "wiki/concepts/cilium.md", frontmatter={"type": "entity", "tags": ["entity"]})}
        errors = check_type_directory_match(pages)
        self.assertTrue(any("TYPE-MISMATCH" in e for e in errors))

    def test_no_frontmatter(self):
        pages = {"bad": make_page("bad", "wiki/entities/bad.md", frontmatter=None)}
        errors = check_type_directory_match(pages)
        self.assertTrue(any("NO-FRONTMATTER" in e for e in errors))

    def test_first_tag_mismatch(self):
        pages = {"x": make_page("x", "wiki/entities/x.md", frontmatter={"type": "entity", "tags": ["concept", "test"]})}
        errors = check_type_directory_match(pages)
        self.assertTrue(any("FIRST-TAG-TYPE" in e for e in errors))


class TestBrokenWikilinks(unittest.TestCase):
    def test_no_broken(self):
        pages = {
            "alpha": make_page("alpha", "wiki/entities/alpha.md", wikilinks=["beta"]),
            "beta": make_page("beta", "wiki/concepts/beta.md", wikilinks=["alpha"]),
        }
        self.assertEqual(check_broken_wikilinks(pages), [])

    def test_broken_link(self):
        pages = {"alpha": make_page("alpha", "wiki/entities/alpha.md", wikilinks=["nonexistent"])}
        errors = check_broken_wikilinks(pages)
        self.assertEqual(len(errors), 1)
        self.assertIn("BROKEN-LINK", errors[0])


class TestOrphans(unittest.TestCase):
    def test_no_orphans(self):
        pages = {
            "alpha": make_page("alpha", "wiki/entities/alpha.md", wikilinks=["beta"]),
            "beta": make_page("beta", "wiki/concepts/beta.md", wikilinks=["alpha"]),
        }
        self.assertEqual(check_orphans(pages), [])

    def test_orphan(self):
        pages = {
            "alpha": make_page("alpha", "wiki/entities/alpha.md", wikilinks=[]),
            "beta": make_page("beta", "wiki/concepts/beta.md", wikilinks=[]),
        }
        errors = check_orphans(pages)
        self.assertEqual(len(errors), 2)


class TestSeeAlso(unittest.TestCase):
    def test_valid_see_also(self):
        content = "# Title\n\n## See Also\n\n- [[a]] — desc\n- [[b]] — desc\n"
        pages = {"x": make_page("x", "wiki/entities/x.md", content=content)}
        self.assertEqual(check_see_also(pages), [])

    def test_missing_see_also(self):
        content = "# Title\n\nNo see also section.\n"
        pages = {"x": make_page("x", "wiki/entities/x.md", content=content)}
        errors = check_see_also(pages)
        self.assertTrue(any("MISSING-SEE-ALSO" in e for e in errors))

    def test_insufficient_see_also(self):
        content = "# Title\n\n## See Also\n\n- [[a]] — only one\n"
        pages = {"x": make_page("x", "wiki/entities/x.md", content=content)}
        errors = check_see_also(pages)
        self.assertTrue(any("INSUFFICIENT-SEE-ALSO" in e for e in errors))


class TestBidirectional(unittest.TestCase):
    def test_bidirectional(self):
        pages = {
            "a": make_page("a", "wiki/entities/a.md", wikilinks=["b"]),
            "b": make_page("b", "wiki/concepts/b.md", wikilinks=["a"]),
        }
        self.assertEqual(check_bidirectional(pages), [])

    def test_unidirectional(self):
        pages = {
            "a": make_page("a", "wiki/entities/a.md", wikilinks=["b"]),
            "b": make_page("b", "wiki/concepts/b.md", wikilinks=[]),
        }
        warnings = check_bidirectional(pages)
        self.assertEqual(len(warnings), 1)
        self.assertIn("UNIDIRECTIONAL", warnings[0])


class TestStale(unittest.TestCase):
    def test_fresh(self):
        pages = {"x": make_page("x", "wiki/entities/x.md", frontmatter={"updated": "2026-05-01"})}
        self.assertEqual(check_stale(pages, 90), [])

    def test_stale(self):
        pages = {"x": make_page("x", "wiki/entities/x.md", frontmatter={"updated": "2020-01-01"})}
        warnings = check_stale(pages, 90)
        self.assertTrue(any("STALE" in w for w in warnings))


class TestParseAll(unittest.TestCase):
    def test_parse_all(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            entity_dir = Path(tmpdir) / "entities"
            entity_dir.mkdir()
            (entity_dir / "test.md").write_text("""---
title: Test
type: entity
created: 2026-01-01
updated: 2026-01-01
sources: []
tags: [entity, test]
---

# Test

Summary. See [[other]].

## See Also

- [[other]] — desc
- [[another]] — desc
""")
            pages = parse_all(tmpdir)
            self.assertEqual(len(pages), 1)
            self.assertIn("test", pages)
            self.assertEqual(pages["test"].frontmatter["type"], "entity")
            self.assertIn("other", pages["test"].wikilinks)
            self.assertIn("[[other]]", pages["test"].content)


if __name__ == "__main__":
    unittest.main()
