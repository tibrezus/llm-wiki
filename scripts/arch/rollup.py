#!/usr/bin/env python3
"""Code-graph rollup: SCIP index -> compact, ranked, token-budgeted map.

This is the deterministic half of the architecture feature. It reads a SCIP
index, builds a symbol reference graph, ranks symbols (Aider-style PageRank over
the reference graph), clusters them by directory, and emits a compact text map
pruned to a token budget. The LLM consumes the map (plus targeted ``scip``
drills) to assign C4 levels and author D2 figures.

Design goals (from the system's premise):

* The ``.scip`` index is the single source of truth and never enters the LLM
  context directly (it is a compact binary).
* ``map.txt`` is the context-sized projection — efficient, ranked, budgeted.
* The rank/rollup core is protobuf-free and unit-testable on synthetic graphs.
"""

from __future__ import annotations

import argparse
import math
import os
import sys
from collections import defaultdict
from typing import Dict, Iterable, List, Set, Tuple

# Add this directory to the path so ``import scip_pb`` works when invoked
# directly (e.g. ``python3 rollup.py ...``).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

GRAPH = Dict
# graph = {
#   "symbols": { sid: {"name":str,"simple":str,"path":str,"lang":str} },
#   "edges":   set of (src_sid, dst_sid),  # src references dst
# }

# ---------------------------------------------------------------------------
# 1. SCIP index -> graph
# ---------------------------------------------------------------------------

def index_to_graph(index) -> GRAPH:
    """Convert a parsed SCIP ``Index`` into the graph dict used by rollup.

    Only symbols that are *defined* in the index become nodes. Edges connect
    two definitions when one references the other (use -> def). References to
    external/undefined symbols are dropped (they carry no in-repo weight).
    """
    import scip_pb  # local; needs the binding

    symbols: Dict[str, dict] = {}
    for sid, display, simple, rel, lang in scip_pb.iter_symbols(index):
        symbols[sid] = {
            "name": display,
            "simple": simple,
            "path": rel,
            "lang": _lang_name(lang),
        }

    edges: Set[Tuple[str, str]] = set()

    # SCIP does not directly encode "who references X". To recover the graph we
    # pair each occurrence with the enclosing document's defined symbols: a
    # definition in document D that has an occurrence of symbol Y implies
    # (definition_in_D -> Y). We approximate the source as the *first*
    # definition in D. For finer precision, the optional SCIP diagnostics field
    # or symbol relationships can be used; this heuristic is sufficient for
    # ranking.
    for doc in index.documents:
        defs_in_doc = [s.symbol for s in doc.symbols if doc.symbols]
        if not defs_in_doc:
            continue
        # Representative source per document: the highest-ranked-looking def is
        # unknown pre-ranking, so use the module-like primary (fewest ".").
        primary = min(defs_in_doc, key=lambda s: s.count(" "))
        for occ in doc.occurrences:
            tgt = occ.symbol
            if tgt in symbols and tgt != primary:
                edges.add((primary, tgt))

    return {"symbols": symbols, "edges": edges}


def _lang_name(lang_enum) -> str:
    try:
        return lang_enum.Name(lang_enum).lower().replace("language_", "")
    except Exception:
        return "unknown"


# ---------------------------------------------------------------------------
# 2. Ranking — Aider-style PageRank over the reference graph
# ---------------------------------------------------------------------------

def rank_graph(graph: GRAPH, *, damping: float = 0.85, iterations: int = 40,
               tol: float = 1e-6) -> Dict[str, float]:
    """Compute a PageRank-style importance score for each symbol.

    Symbols that are referenced by many important symbols rank higher — the
    Aider repo-map intuition that widely-referenced definitions are the
    load-bearing structure worth showing first.
    """
    syms = graph["symbols"]
    edges = graph["edges"]
    n = len(syms)
    if n == 0:
        return {}

    # out-degree
    out_deg: Dict[str, int] = defaultdict(int)
    in_adj: Dict[str, List[str]] = defaultdict(list)
    for src, dst in edges:
        out_deg[src] += 1
        in_adj[dst].append(src)

    rank: Dict[str, float] = {s: 1.0 / n for s in syms}
    base = (1.0 - damping) / n
    for _ in range(iterations):
        new_rank: Dict[str, float] = {}
        delta = 0.0
        for s in syms:
            incoming = in_adj.get(s, [])
            acc = 0.0
            for src in incoming:
                od = out_deg.get(src, 0)
                if od > 0:
                    acc += damping * (rank[src] / od)
            # dangling source redistribution (uniform)
            new_rank[s] = base + acc
            delta += abs(new_rank[s] - rank[s])
        rank = new_rank
        if delta < tol:
            break
    return rank


# ---------------------------------------------------------------------------
# 3. Clustering — group symbols by directory tree
# ---------------------------------------------------------------------------

def cluster_symbols(graph: GRAPH) -> Dict[Tuple[str, ...], List[str]]:
    """Group symbol ids by their directory path components.

    Returns a mapping ``cluster_path -> [symbol_ids]`` where ``cluster_path``
    is a tuple of directory segments (e.g. ``("pkg", "server")``). This gives
    the natural nested structure that mirrors D2/container nesting and the
    file system layout Aider's map also follows.
    """
    clusters: Dict[Tuple[str, ...], List[str]] = defaultdict(list)
    for sid, meta in graph["symbols"].items():
        p = meta["path"]
        # Strip leading "./" and the filename.
        p = p.replace("\\", "/").lstrip("./")
        parts = [seg for seg in p.split("/") if seg and seg != "."]
        if parts:
            parts = parts[:-1]  # drop filename
        clusters[tuple(parts)].append(sid)
    return clusters


# ---------------------------------------------------------------------------
# 4. Token-budgeted rollup
# ---------------------------------------------------------------------------

_APPROX_TOKENS_PER_CHAR = 0.25  # ~4 chars/token for source-ish text


def _est_tokens(text: str) -> int:
    return max(1, int(len(text) * _APPROX_TOKENS_PER_CHAR))


def _emit_header(name: str, budget_used: int, budget: int) -> str:
    return (
        f"# Code Graph Rollup — {name}\n"
        f"# Ranked symbol map (PageRank over reference graph), pruned to "
        f"~{budget} tokens. {budget_used} used.\n"
        "# Read this for orientation; drill the .scip for detail.\n\n"
    )


def rollup(graph: GRAPH, ranks: Dict[str, float], *, name: str = "project",
           budget: int = 8000) -> str:
    """Render the compact ranked map within a token budget.

    Symbols are ranked globally; within each directory cluster we emit the
    top-ranked symbols first. Clusters themselves are ordered by their best
    symbol rank, so the most important neighborhoods surface first and the
    budget is spent on the highest-value structure.
    """
    clusters = cluster_symbols(graph)
    syms = graph["symbols"]

    # Rank each cluster by its top symbol; sort clusters desc.
    def cluster_key(path_ids):
        ids = path_ids[1]
        if not ids:
            return -1.0
        return max(ranks.get(i, 0.0) for i in ids)

    ordered_clusters = sorted(clusters.items(), key=cluster_key, reverse=True)

    # Pre-rank symbols within each cluster (desc).
    ranked_in_cluster = {
        path: sorted(ids, key=lambda i: ranks.get(i, 0.0), reverse=True)
        for path, ids in clusters.items()
    }

    lines: List[str] = []
    used = 0
    header_pad = 120  # reserve for header; recomputed at the end
    budget_eff = budget - header_pad
    emitted_symbols = 0
    emitted_clusters = 0
    truncated = False

    for path, ids in ordered_clusters:
        if used >= budget_eff:
            truncated = True
            break
        cluster_label = "/".join(path) if path else "<root>"
        cluster_line = f"{cluster_label}/"
        # Show the cluster's aggregate importance for orientation.
        top_rank = ranks.get(ids[0], 0.0) if ids else 0.0
        cluster_line += f"  # top-rank={top_rank:.4f}"
        if _est_tokens(cluster_line) + used > budget_eff:
            truncated = True
            break
        lines.append(cluster_line)
        used += _est_tokens(cluster_line)
        emitted_clusters += 1
        wrote_sym = False
        for sid in ranked_in_cluster[path]:
            meta = syms[sid]
            sym_line = f"    . {meta['simple']}  # r={ranks.get(sid,0.0):.4f}"
            cost = _est_tokens(sym_line)
            if used + cost > budget_eff:
                truncated = True
                break
            lines.append(sym_line)
            used += cost
            emitted_symbols += 1
            wrote_sym = True
        if not wrote_sym:
            # cluster header alone: keep it, it signals structure exists.
            pass
        lines.append("")
        if truncated:
            break

    header = _emit_header(name, used, budget)
    # Re-budget header to actual estimate and re-evaluate truncation flag.
    header_tokens = _est_tokens(header)
    # The reserve was approximate; clamp usage note.
    out = header + "\n".join(lines).rstrip() + "\n"
    if truncated:
        out += f"\n(pruned: budget ~{budget} tokens reached)\n"
    out += (
        f"\n# {emitted_symbols} symbols across {emitted_clusters} clusters.\n"
    )
    return out


# ---------------------------------------------------------------------------
# 5. CLI
# ---------------------------------------------------------------------------

def main(argv: Iterable[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Rollup a SCIP index into a compact ranked map."
    )
    p.add_argument("scip", help="path to the .scip index file")
    p.add_argument("-o", "--out", help="output .map.txt path (default: stdout)")
    p.add_argument("-n", "--name", default="project", help="project name label")
    p.add_argument("-b", "--budget", type=int, default=8000,
                   help="approx token budget (default: 8000)")
    args = p.parse_args(list(argv) if argv is not None else None)

    import scip_pb
    index = scip_pb.load_index(args.scip)
    graph = index_to_graph(index)
    ranks = rank_graph(graph)
    text = rollup(graph, ranks, name=args.name, budget=args.budget)

    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
        print(f"wrote {args.out} ({len(text)} chars)", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
