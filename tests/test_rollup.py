#!/usr/bin/env python3
"""Unit tests for scripts/arch/rollup.py — ranking, clustering, budgeting.

These exercise the protobuf-free core (rank_graph / cluster_symbols / rollup)
on synthetic graphs, so they run without the SCIP binding installed.
"""

import os
import sys
import unittest

# Make scripts/arch importable.
_ARCH = os.path.join(os.path.dirname(__file__), "..", "scripts", "arch")
sys.path.insert(0, os.path.abspath(_ARCH))

import rollup  # noqa: E402


def _graph(symbols, edges):
    """Build a graph dict from {sid: (simple, path)} and edge list."""
    syms = {
        sid: {"name": simple, "simple": simple, "path": path, "lang": "go"}
        for sid, (simple, path) in symbols.items()
    }
    return {"symbols": syms, "edges": set(edges)}


class TestRank(unittest.TestCase):
    def test_empty_graph(self):
        self.assertEqual(rollup.rank_graph({"symbols": {}, "edges": set()}), {})

    def test_referenced_symbol_ranks_higher(self):
        # hub is referenced by two leaves; a leaf by nobody.
        g = _graph(
            {
                "hub": ("Hub", "pkg/hub.go"),
                "a": ("A", "pkg/a.go"),
                "b": ("B", "pkg/b.go"),
            },
            edges=[("a", "hub"), ("b", "hub"), ("hub", "a")],
        )
        ranks = rollup.rank_graph(g)
        self.assertGreater(ranks["hub"], ranks["b"])
        self.assertGreater(ranks["hub"], ranks["a"])

    def test_ranks_sum_to_one(self):
        g = _graph(
            {"x": ("X", "x.go"), "y": ("Y", "y.go"), "z": ("Z", "z.go")},
            edges=[("x", "y"), ("y", "z"), ("z", "x")],
        )
        ranks = rollup.rank_graph(g)
        self.assertAlmostEqual(sum(ranks.values()), 1.0, places=3)


class TestCluster(unittest.TestCase):
    def test_clusters_by_directory(self):
        g = _graph(
            {
                "s1": ("S1", "pkg/server/handler.go"),
                "s2": ("S2", "pkg/server/util.go"),
                "s3": ("S3", "cmd/main.go"),
            },
            edges=[],
        )
        clusters = rollup.cluster_symbols(g)
        self.assertIn(("pkg", "server"), clusters)
        self.assertIn(("cmd",), clusters)  # cmd/main.go -> ('cmd',)
        self.assertEqual(len(clusters[("pkg", "server")]), 2)

    def test_strips_leading_dot_slash(self):
        g = _graph({"s": ("S", "./pkg/x.go")}, edges=[])
        clusters = rollup.cluster_symbols(g)
        self.assertIn(("pkg",), clusters)


class TestRollup(unittest.TestCase):
    def test_budget_truncates(self):
        syms = {f"s{i}": (f"S{i}", f"pkg/mod{i}/f.go") for i in range(200)}
        g = _graph(syms, edges=[])
        ranks = rollup.rank_graph(g)
        text = rollup.rollup(g, ranks, name="big", budget=500)
        # Must be well under a generous char estimate for a 500-token budget.
        self.assertLess(len(text), 6000)
        self.assertIn("pruned", text)

    def test_emits_clusters_and_symbols(self):
        g = _graph(
            {
                "h": ("Hub", "pkg/hub.go"),
                "a": ("A", "pkg/hub.go"),
            },
            edges=[("a", "h")],
        )
        ranks = rollup.rank_graph(g)
        text = rollup.rollup(g, ranks, name="small", budget=8000)
        self.assertIn("pkg/", text)
        self.assertIn("Hub", text)
        self.assertIn("Code Graph Rollup", text)

    def test_clusters_ordered_by_top_rank(self):
        g = _graph(
            {
                "hot": ("Hot", "a/hot.go"),
                "cold": ("Cold", "b/cold.go"),
            },
            edges=[("cold", "hot")],
        )
        ranks = rollup.rank_graph(g)
        text = rollup.rollup(g, ranks, name="p", budget=8000)
        self.assertLess(text.index("a/"), text.index("b/"))


if __name__ == "__main__":
    unittest.main()
