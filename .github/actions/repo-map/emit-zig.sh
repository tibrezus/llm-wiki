#!/usr/bin/env bash
set -euo pipefail

# RIG emitter for Zig projects.
# Parses build.zig (modules + executables + imports) and build.zig.zon
# (project metadata + external dependencies) to produce a RIG JSON
# conforming to schemas/repo-map.schema.yaml.
#
# Usage: emit-zig.sh <output.json>

OUT="${1:?Usage: emit-zig.sh <output.json>}"

command -v python3 >/dev/null 2>&1 || { echo "::error::python3 not found on PATH"; exit 1; }

python3 - "$OUT" <<'PYEOF'
import json, os, re, subprocess, sys
from datetime import datetime, timezone

out_path = sys.argv[1]

# ---------------------------------------------------------------------------
# 1. Parse build.zig.zon for project metadata + external dependencies.
# ---------------------------------------------------------------------------
zon_path = "build.zig.zon"
project_name = os.path.basename(os.getcwd())
zig_version_required = ""

if os.path.exists(zon_path):
    with open(zon_path) as f:
        zon = f.read()
    m = re.search(r'\.name\s*=\s*\.(\w+)', zon)
    if m:
        project_name = m.group(1)
    m = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon)
    if m:
        zig_version_required = m.group(1)

# ---------------------------------------------------------------------------
# 2. Parse build.zig for modules, executables, and import mappings.
# ---------------------------------------------------------------------------
build_path = "build.zig"
with open(build_path) as f:
    build_src = f.read()

# Module variable → (root_source_file, module_name_or_None)
# Matches both b.addModule("Name", .{ .root_source_file = b.path("path") })
# and      b.createModule(.{ .root_source_file = b.path("path") })
modules = {}  # var_name → { "root": "src/lib.zig", "module_name": "rhesadox" or None }

for m in re.finditer(
    r'(?:const\s+)?(\w+)\s*=\s*b\.addModule\(\s*"([^"]+)".*?'
    r'\.root_source_file\s*=\s*b\.path\(\s*"([^"]+)"\s*\)',
    build_src, re.DOTALL
):
    modules[m.group(1)] = {"root": m.group(3), "module_name": m.group(2)}

for m in re.finditer(
    r'(?:const\s+)?(\w+)\s*=\s*b\.createModule\(\s*\.\{\s*'
    r'\.root_source_file\s*=\s*b\.path\(\s*"([^"]+)"\s*\)',
    build_src, re.DOTALL
):
    var = m.group(1)
    if var not in modules:
        modules[var] = {"root": m.group(2), "module_name": None}

# Also handle addModule where root_source_file is on a different line pattern
for m in re.finditer(
    r'(?:const\s+)?(\w+)\s*=\s*b\.addModule\(\s*"([^"]+)".*?'
    r'\.root_source_file\s*=\s*(\w+)\.path\(\s*"([^"]+)"\s*\)',
    build_src, re.DOTALL
):
    var = m.group(1)
    if var not in modules:
        modules[var] = {"root": m.group(4), "module_name": m.group(2)}

# Executables: var → { name, root_module_var }
executables = {}  # exe_var → { "name": "rhesadox", "mod_var": "exe_mod" }
for m in re.finditer(
    r'(?:const\s+)?(\w+)\s*=\s*b\.addExecutable\(\s*\.\{[^}]*?'
    r'\.name\s*=\s*"([^"]+)"[^}]*?\.root_module\s*=\s*(\w+)',
    build_src, re.DOTALL
):
    executables[m.group(1)] = {"name": m.group(2), "mod_var": m.group(3)}

# Import mappings: from_var.addImport("import_name", to_var)
# These tell us module dependencies (from_var imports to_var as import_name).
imports = {}  # from_var → list of (import_name, to_var)
for m in re.finditer(
    r'(\w+)\.addImport\(\s*"([^"]+)"\s*,\s*(\w+)\s*\)',
    build_src
):
    from_var = m.group(1)
    imports.setdefault(from_var, []).append((m.group(2), m.group(3)))

# ---------------------------------------------------------------------------
# 3. Scan source files for @import() to build the source-file tree.
# ---------------------------------------------------------------------------
def scan_imports(filepath):
    """Return (file_imports, all_reachable_files) for a .zig source file.
    
    file_imports: list of import strings (both relative paths and named modules)
    """
    try:
        with open(filepath) as f:
            src = f.read()
    except (IOError, OSError):
        return [], []
    
    file_imports = []
    for m in re.finditer(r'@import\(\s*"([^"]+)"\s*\)', src):
        file_imports.append(m.group(1))
    return file_imports

def collect_source_files(root_file):
    """Transitively collect all .zig source files reachable from root_file
    via @import("relative/path.zig") calls."""
    visited = set()
    queue = [root_file]
    result = []
    
    while queue:
        current = queue.pop(0)
        if current in visited:
            continue
        visited.add(current)
        
        if os.path.exists(current):
            result.append(current)
            file_dir = os.path.dirname(current)
            file_imports = scan_imports(current)
            for imp in file_imports:
                # Only follow relative path imports (contain .zig), not named modules
                if imp.endswith(".zig"):
                    resolved = os.path.normpath(os.path.join(file_dir, imp))
                    if resolved not in visited:
                        queue.append(resolved)
    
    return sorted(result)

def get_named_imports(root_file):
    """Get the set of named module imports (non-path) from a root file's
    transitive closure."""
    visited = set()
    queue = [root_file]
    named_imports = set()
    
    while queue:
        current = queue.pop(0)
        if current in visited:
            continue
        visited.add(current)
        
        if not os.path.exists(current):
            continue
        file_dir = os.path.dirname(current)
        file_imports = scan_imports(current)
        for imp in file_imports:
            if imp.endswith(".zig"):
                resolved = os.path.normpath(os.path.join(file_dir, imp))
                if resolved not in visited:
                    queue.append(resolved)
            else:
                # Named module import (e.g., @import("rhesadox"))
                named_imports.add(imp)
    
    return named_imports

# ---------------------------------------------------------------------------
# 4. Build RIG components.
# ---------------------------------------------------------------------------
components = []
comp_id_map = {}  # key → component id
module_name_to_var = {}  # "rhesadox" → engine_mod (for resolving named imports)
next_id = 1

def make_id():
    global next_id
    cid = f"comp-{next_id}"
    next_id += 1
    return cid

# Create components for named modules (b.addModule)
for var, info in modules.items():
    if info["module_name"] is not None:
        cid = make_id()
        key = f"module:{var}"
        comp_id_map[key] = cid
        module_name_to_var[info["module_name"]] = var
        components.append({
            "id": cid,
            "name": info["module_name"],
            "type": "package_library",
            "programming_language": "zig",
            "source_files": collect_source_files(info["root"]),
            "depends_on_ids": [],
            "external_packages_ids": [],
        })

# Create components for executables
entrypoints = []
for exe_var, info in executables.items():
    mod_var = info["mod_var"]
    mod_info = modules.get(mod_var, {"root": None, "module_name": None})
    root_file = mod_info.get("root")
    
    cid = make_id()
    key = f"exe:{exe_var}"
    comp_id_map[key] = cid
    
    source_files = collect_source_files(root_file) if root_file else []
    
    # Resolve named imports to component dependencies
    depends_on = set()
    if root_file:
        for named_imp in get_named_imports(root_file):
            dep_var = module_name_to_var.get(named_imp)
            if dep_var:
                dep_key = f"module:{dep_var}"
                if dep_key in comp_id_map:
                    depends_on.add(comp_id_map[dep_key])
    
    # Also check addImport mappings on the exe's module var
    for imp_name, to_var in imports.get(mod_var, []):
        dep_key = f"module:{to_var}"
        if dep_key in comp_id_map:
            depends_on.add(comp_id_map[dep_key])
    
    components.append({
        "id": cid,
        "name": info["name"],
        "type": "executable",
        "programming_language": "zig",
        "source_files": source_files,
        "depends_on_ids": sorted(depends_on),
        "external_packages_ids": [],
    })
    entrypoints.append(cid)

# ---------------------------------------------------------------------------
# 5. External packages from build.zig.zon dependencies.
# ---------------------------------------------------------------------------
external_packages = []
next_ep_id = 1

if os.path.exists(zon_path):
    with open(zon_path) as f:
        zon = f.read()
    # Parse .dependencies = .{ ... } with proper brace matching.
    dep_match = re.search(r'\.dependencies\s*=\s*\.\{', zon)
    if dep_match:
        # Find the matching closing brace by counting depth.
        start = dep_match.end()
        depth = 1
        i = start
        while i < len(zon) and depth > 0:
            if zon[i] == '{':
                depth += 1
            elif zon[i] == '}':
                depth -= 1
            i += 1
        dep_block = zon[start:i - 1] if depth == 0 else ""
        # Each dependency is .name = .{ ... }
        for m in re.finditer(r'\.(\w+)\s*=\s*\.\{', dep_block):
            dep_name = m.group(1)
            eid = f"pkg-{next_ep_id}"
            next_ep_id += 1
            external_packages.append({
                "id": eid,
                "name": dep_name,
                "package_manager": {
                    "name": "zig-modules",
                    "package_name": dep_name,
                }
            })

# ---------------------------------------------------------------------------
# 6. Assemble RIG.
# ---------------------------------------------------------------------------
git_ref = ""
if os.path.exists(".git"):
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True
        )
        git_ref = r.stdout.strip()
    except Exception:
        pass

rig = {
    "schema_version": "rig-1.0",
    "repository": {
        "name": project_name,
        "ref": git_ref,
        "language": "zig",
        "build_system": "zig",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
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
    f"RIG: {len(components)} components, "
    f"{len(external_packages)} external packages, "
    f"{len(entrypoints)} entrypoints",
    file=sys.stderr
)
PYEOF
