#!/usr/bin/env bash
set -euo pipefail

# RIG emitter for Zig projects.
#
# Two-layer analysis:
#   Layer 1 — Build targets: parse build.zig for executables, modules, tests
#   Layer 2 — Source units:  scan .zig files, parse @import() for dependency graph
#
# Every source file becomes a component. Every @import("foo.zig") creates a
# dependency edge. CUDA .cu and C .c files are also captured. This gives the
# LLM agent a complete architectural picture to derive the C4 model from.
#
# Usage: emit-zig.sh <output.json>

OUT="${1:?Usage: emit-zig.sh <output.json>}"

command -v zig >/dev/null 2>&1 || { echo "::error::zig not found on PATH"; exit 1; }
[ -f "build.zig" ] || { echo "::error::Not a Zig project (no build.zig)"; exit 1; }

ZIG_VERSION=$(zig version 2>/dev/null || echo "unknown")

python3 - "$OUT" "$ZIG_VERSION" <<'PYEOF'
import json, os, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

out_path = sys.argv[1]
zig_version = sys.argv[2]

build_zig = Path("build.zig").read_text(encoding="utf-8", errors="replace")
build_zon_text = ""
if Path("build.zig.zon").exists():
    build_zon_text = Path("build.zig.zon").read_text(encoding="utf-8", errors="replace")

components = []
comp_by_name = {}    # component name → id
comp_by_file = {}    # source file path → id (for import resolution)
ext_pkg_map = {}
entrypoints = []
next_id = 1
next_epid = 1

def cid():
    global next_id
    v = f"comp-{next_id}"; next_id += 1; return v

def epid():
    global next_epid
    v = f"pkg-{next_epid}"; next_epid += 1; return v

def add_dep(consumer_id, provider_id):
    """Add a dependency edge, avoiding duplicates."""
    for c in components:
        if c["id"] == consumer_id:
            if provider_id not in c["depends_on_ids"]:
                c["depends_on_ids"].append(provider_id)
            return

# ============================================================
# Layer 1: Build targets from build.zig
# ============================================================

# Executables: addExecutable with .name = "..."
exe_re = re.compile(
    r'addExecutable\s*\(\s*\.\{\s*(?:.*?\s)?\.name\s*=\s*"([^"]+)"',
    re.DOTALL,
)
exe_var_map = {}  # variable name → exe name

for m in exe_re.finditer(build_zig):
    name = m.group(1)
    comp_id = cid()
    comp_by_name[name] = comp_id
    after = build_zig[m.end():m.end() + 300]
    src_match = re.search(r'\.root_source_file\s*=\s*b\.path\("([^"]+)"\)', after)
    root_file = src_match.group(1) if src_match else ""
    components.append({
        "id": comp_id,
        "name": name,
        "type": "executable",
        "programming_language": "zig",
        "source_files": [root_file] if root_file else [],
        "external_packages_ids": [],
        "depends_on_ids": [],
    })
    entrypoints.append(comp_id)
    if root_file:
        comp_by_file[root_file] = comp_id

# Also capture variable assignments: const exe = b.addExecutable(...)
assign_exe = re.compile(
    r'(?:const|var)\s+(\w+)\s*=\s*\S*addExecutable\s*\(\s*\.\{\s*(?:.*?\s)?\.name\s*=\s*"([^"]+)"',
    re.DOTALL,
)
for m in assign_exe.finditer(build_zig):
    exe_var_map[m.group(1)] = m.group(2)

# Modules: addModule("name", .{ ... }) or addModule(.{ .name = "..." })
mod_re = re.compile(r'addModule\s*\(\s*"([^"]+)"')
for m in mod_re.finditer(build_zig):
    name = m.group(1)
    if name not in comp_by_name:
        comp_id = cid()
        comp_by_name[name] = comp_id
        after = build_zig[m.end():m.end() + 300]
        src_match = re.search(r'\.root_source_file\s*=\s*b\.path\("([^"]+)"\)', after)
        root_file = src_match.group(1) if src_match else ""
        components.append({
            "id": comp_id,
            "name": name,
            "type": "package_library",
            "programming_language": "zig",
            "source_files": [root_file] if root_file else [],
            "external_packages_ids": [],
            "depends_on_ids": [],
        })
        if root_file:
            comp_by_file[root_file] = comp_id

# Also match: .root_source_file = b.path("src/lib.zig") in addModule struct form
mod_struct_re = re.compile(
    r'addModule\s*\(\s*\.\{\s*(?:.*?\s)?\.name\s*=\s*\.(\w+)'
)
for m in mod_struct_re.finditer(build_zig):
    name = m.group(1)
    if name not in comp_by_name:
        comp_id = cid()
        comp_by_name[name] = comp_id
        after = build_zig[m.end():m.end() + 300]
        src_match = re.search(r'\.root_source_file\s*=\s*b\.path\("([^"]+)"\)', after)
        root_file = src_match.group(1) if src_match else ""
        components.append({
            "id": comp_id,
            "name": name,
            "type": "package_library",
            "programming_language": "zig",
            "source_files": [root_file] if root_file else [],
            "external_packages_ids": [],
            "depends_on_ids": [],
        })
        if root_file:
            comp_by_file[root_file] = comp_id

# Variable → component mapping for addImport resolution
var_to_comp = {}
for m in re.finditer(
    r'(?:const|var)\s+(\w+)\s*=\s*b\.(?:addModule|createModule)\s*\(\s*(?:\.\{\s*)?(?:.*?\s)?\.name\s*=\s*"?\.?(\w+)"?',
    build_zig, re.DOTALL
):
    var_name, mod_name = m.group(1), m.group(2)
    if mod_name in comp_by_name:
        var_to_comp[var_name] = comp_by_name[mod_name]

# Resolve addImport edges between build targets
for regex in [
    re.compile(r'(\w+)\.addImport\s*\(\s*"([^"]+)"\s*,\s*(\w+)\s*\)'),
    re.compile(r'(\w+)\.root_module\.addImport\s*\(\s*"([^"]+)"\s*,\s*(\w+)\s*\)'),
]:
    for m in regex.finditer(build_zig):
        consumer_var, alias, provider_var = m.group(1), m.group(2), m.group(3)
        consumer_cid = var_to_comp.get(consumer_var) or comp_by_name.get(exe_var_map.get(consumer_var, ""))
        provider_cid = var_to_comp.get(provider_var) or comp_by_name.get(exe_var_map.get(provider_var, ""))
        if consumer_cid and provider_cid and consumer_cid != provider_cid:
            add_dep(consumer_cid, provider_cid)

# ============================================================
# Layer 2: Source file analysis (@import graph)
# ============================================================

# Find all .zig source files
zig_files = []
for root_dir in ["src", "tools"]:
    if Path(root_dir).exists():
        for p in Path(root_dir).rglob("*.zig"):
            zig_files.append(str(p))

# Create a component per source file (if not already the root of a build target)
for fpath in sorted(zig_files):
    if fpath in comp_by_file:
        continue  # already a build target root file
    # Derive component name from filename
    name = Path(fpath).stem
    # Avoid name collisions
    if name in comp_by_name:
        name = f"{Path(fpath).parent.name}_{name}"
    if name in comp_by_name:
        continue
    comp_id = cid()
    comp_by_name[name] = comp_id
    comp_by_file[fpath] = comp_id
    components.append({
        "id": comp_id,
        "name": name,
        "type": "component",
        "programming_language": "zig",
        "source_files": [fpath],
        "external_packages_ids": [],
        "depends_on_ids": [],
    })

# Parse @import() calls to build the dependency graph
import_re = re.compile(r'@import\s*\(\s*"([^"]+)"\s*\)')
for fpath in zig_files:
    consumer_id = comp_by_file.get(fpath)
    if not consumer_id:
        continue
    try:
        content = Path(fpath).read_text(encoding="utf-8", errors="replace")
    except Exception:
        continue
    for m in import_re.finditer(content):
        target = m.group(1)
        # Resolve relative imports
        if target.startswith("."):
            resolved = str((Path(fpath).parent / target).resolve())
            # Try to normalize relative to project root
            try:
                resolved = str(Path(resolved).relative_to(Path.cwd()))
            except ValueError:
                pass
        else:
            resolved = target
        # Skip std library imports
        if resolved in ("std", "config", "builtin"):
            continue
        # Find the target component
        provider_id = comp_by_file.get(resolved)
        if not provider_id:
            # Try with src/ prefix
            for prefix in ["", "src/", "tools/"]:
                if prefix + resolved in comp_by_file:
                    provider_id = comp_by_file[prefix + resolved]
                    break
        if provider_id and provider_id != consumer_id:
            add_dep(consumer_id, provider_id)

# ============================================================
# Layer 2b: CUDA and C source files
# ============================================================

for pattern, lang in [("cuda/**/*.cu", "cuda"), ("c/**/*.c", "c"), ("*.cu", "cuda"), ("*.c", "c")]:
    for p in Path(".").glob(pattern):
        if "zig-cache" in str(p) or "zig-out" in str(p):
            continue
        fpath = str(p)
        if fpath in comp_by_file:
            continue
        name = p.stem
        if name in comp_by_name:
            name = f"{lang}_{name}"
        if name in comp_by_name:
            continue
        comp_id = cid()
        comp_by_name[name] = comp_id
        comp_by_file[fpath] = comp_id
        components.append({
            "id": comp_id,
            "name": name,
            "type": "component",
            "programming_language": lang,
            "source_files": [fpath],
            "external_packages_ids": [],
            "depends_on_ids": [],
        })

# ============================================================
# External packages from build.zig.zon
# ============================================================

if build_zon_text:
    deps_match = re.search(r'\.dependencies\s*=\s*\.\{', build_zon_text)
    if deps_match:
        start = deps_match.end()
        depth = 1
        pos = start
        while pos < len(build_zon_text) and depth > 0:
            if build_zon_text[pos] == '{':
                depth += 1
            elif build_zon_text[pos] == '}':
                depth -= 1
            pos += 1
        deps_block = build_zon_text[start:pos - 1]
        for dm in re.finditer(r'\.(\w+)\s*=\s*\.\{', deps_block):
            dep_name = dm.group(1)
            eid = epid()
            ext_pkg_map[dep_name] = eid

external_packages = []
for name, eid in sorted(ext_pkg_map.items()):
    external_packages.append({
        "id": eid,
        "name": name,
        "package_manager": {"name": "zig-modules", "package_name": name},
    })

# ============================================================
# Repository metadata
# ============================================================

project_name = "zig-project"
if build_zon_text:
    name_match = re.search(r'\.name\s*=\s*\.(\w+)', build_zon_text)
    if name_match:
        project_name = name_match.group(1)

git_ref = ""
if Path(".git").exists():
    try:
        r = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                           capture_output=True, text=True, timeout=5)
        git_ref = r.stdout.strip()
    except Exception:
        pass

rig = {
    "schema_version": "rig-1.0",
    "repository": {
        "name": project_name,
        "ref": git_ref,
        "language": "zig",
        "build_system": "zig-build",
        "generator": "tibrezus/llm-wiki/.github/actions/repo-map@v1",
    },
    "components": components,
    "aggregators": [],
    "runners": [],
    "test_definitions": [],
    "external_packages": external_packages,
    "entrypoints": entrypoints,
}

with open(out_path, "w") as f:
    json.dump(rig, f, indent=2)

print(
    f"RIG: {len(components)} components "
    f"({sum(1 for c in components if c['type'] == 'executable')} executables, "
    f"{sum(1 for c in components if c['type'] == 'package_library')} libraries, "
    f"{sum(1 for c in components if c['type'] == 'component')} source units), "
    f"{sum(len(c.get('depends_on_ids', [])) for c in components)} dependency edges, "
    f"{len(external_packages)} external packages, "
    f"{len(entrypoints)} entrypoints",
    file=sys.stderr,
)
PYEOF
