#!/usr/bin/env python3
"""SCIP protobuf binding loader.

Vendored ``scip.proto`` is compiled to a Python ``_pb2`` module on demand and
cached next to this file, keyed by the installed protobuf runtime version, so
the binding always matches the runtime and survives upgrades.

Public API:

    from scip_pb import load_index, iter_symbols, iter_references

``load_index(path)`` returns a parsed ``scip_pb2.Index``. The other helpers are
thin convenience wrappers used by ``rollup.py``.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
from pathlib import Path

_THIS = Path(__file__).resolve().parent
_PROTO = _THIS / "scip.proto"
_CACHE = _THIS / "_pb_cache"


def _protobuf_version() -> tuple[int, int, int]:
    import google.protobuf  # noqa: WPS433 (optional dep, imported lazily)
    parts = google.protobuf.__version__.split(".")[:3]
    while len(parts) < 3:
        parts.append("0")
    return tuple(int(p.split("-")[0]) for p in parts)  # type: ignore[return-value]


def _ensure_binding() -> "object":
    """Return the compiled ``scip_pb2`` module, generating it if needed."""
    try:
        import google.protobuf  # noqa: F401
    except ImportError as exc:  # pragma: no cover - environment error
        raise SystemExit(
            "ERROR: protobuf runtime not installed. "
            "Install with: pip install protobuf"
        ) from exc

    import google.protobuf as _gp
    version_key = _gp.__version__
    cache_dir = _CACHE / version_key
    cache_dir.mkdir(parents=True, exist_ok=True)
    cached = cache_dir / "scip_pb2.py"

    if not cached.exists():
        if not _PROTO.exists():
            raise SystemExit(f"ERROR: vendored scip.proto missing: {_PROTO}")
        protoc = os.environ.get("PROTOC", "protoc")
        try:
            subprocess.run(
                [protoc, f"--python_out={cache_dir.as_posix()}",
                 f"-I{_THIS.as_posix()}", _PROTO.name],
                check=True, cwd=_THIS,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
        except FileNotFoundError as exc:
            raise SystemExit(
                f"ERROR: protoc ('{protoc}') not found. Install protoc or set "
                "the PROTOC env var."
            ) from exc
        except subprocess.CalledProcessError as exc:
            raise SystemExit(
                "ERROR: scip.proto compilation failed:\n" +
                exc.stderr.decode("utf-8", "replace")
            ) from exc

    sys.path.insert(0, cache_dir.as_posix())
    import scip_pb2  # type: ignore  # noqa: WPS433
    return scip_pb2


# Role bitmask (subset of scip.SymbolRole relevant to us).
_DEFINITION_ROLE = 1


def load_index(path: str | os.PathLike):
    """Parse a ``.scip`` file into an ``scip_pb2.Index``."""
    scip_pb2 = _ensure_binding()
    idx = scip_pb2.Index()
    with open(path, "rb") as fh:
        idx.ParseFromString(fh.read())
    return idx


def _signature_info(symbol_info) -> tuple[str, str]:
    """Best-effort display name + simple name for a SymbolInformation.

    SCIP symbol IDs are opaque globally-unique strings. We surface a readable
    name from ``display_name`` if present, else from the last descriptor.
    """
    display = getattr(symbol_info, "display_name", "") or ""
    sig = getattr(symbol_info, "signature", None)
    simple = display
    if sig and sig.simple_name:
        simple = sig.simple_name
    return display or simple, simple


def iter_symbols(index):
    """Yield ``(symbol_id, display_name, simple_name, relative_path, language)``
    for every defined symbol in the index."""
    for doc in index.documents:
        rel = doc.relative_path
        for sym in doc.symbols:
            display, simple = _signature_info(sym)
            yield sym.symbol, display, simple, rel, doc.language


def iter_references(index):
    """Yield ``(symbol_id, role)`` for every occurrence.

    A reference with the definition role bit set marks the occurrence's symbol
    as *defined here*; without it, the occurrence is a *use* of that symbol.
    Rollup uses the symbol set from ``iter_symbols`` plus these occurrences to
    build the reference graph (which definitions reference which)."""
    for doc in index.documents:
        for occ in doc.occurrences:
            yield occ.symbol, int(occ.symbol_roles)
