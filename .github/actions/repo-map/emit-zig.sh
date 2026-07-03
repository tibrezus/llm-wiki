#!/usr/bin/env bash
set -euo pipefail

# RIG emitter for Zig projects.
# Parses build.zig (component declarations) and build.zig.zon (external
# dependencies) to produce a RIG JSON conforming to schemas/repo-map.schema.yaml.
#
# Zig's build system is programmatic — build.zig is code that calls
# b.addExecutable(), b.addModule(), etc. There is no `zig list -json` like
# Go's `go list`. This emitter does static analysis of the build file
# patterns, which captures the common case deterministically.
#
# Usage: emit-zig.sh <output.json>

OUT="${1:?Usage: emit-zig.sh <output.json>}"

# Verify zig is available (needed for version reporting; parsing is static).
command -v zig >/dev/null 2>&1 || { echo "::error::zig not found on PATH"; exit 1; }

[ -f "build.zig" ] || { echo "::error::Not a Zig project (no build.zig)"; exit 1; }

ZIG_VERSION=$(zig version 2>/dev/null || echo "unknown")

python3 - "$OUT" "$ZIG_VERSION" <<'PYEOF'
import json, os, re, subprocess, sys
from datetime import datetime, timezone

out_path = sys.argv[1]
zig_version = sys.argv[2]

build_zig = open("build.zig", encoding="utf-8", errors="replace").read()
build_zon_text = ""
if os.path.isfile("build.zig.zon"):
    build_zon_text = open("build.zig.zon", encoding="utf-8", errors="replace").read()

components = []
comp_id_map = {}  # (name, type) -> id
ext_pkg_map = {}  # name -> id
entrypoints = []
next_id = 1
next_ep_id = 1

def make_id():
    global next_id
    cid = f"comp-{next_id}"
    next_id += 1
    return cid

def make_epid():
    global next_ep_id
    eid = f"pkg-{next_ep_id}"
    next_ep_id += 1
    return eid

# --- Parse components from build.zig ---
#
# Patterns we look for:
#   b.addExecutable(.{ .name = "foo", .root_source_file = b.path("src/main.zig"), ... })
#   const exe = b.addExecutable(.{ .name = "foo", ... })
#   b.addModule("bar", .{ .root_source_file = b.path("src/bar.zig"), ... })
#   const mod = b.addModule("bar", .{ ... })

# Executables: addExecutable with .name = "..."
exe_re = re.compile(
    r'addExecutable\s*\(\s*\.\{\s*(?:.*?\s)?\.name\s*=\s*"([^"]+)"',
    re.DOTALL,
)
for m in exe_re.finditer(build_zig):
    name = m.group(1)
    cid = make_id()
    key = (name, "executable")
    comp_id_map[key] = cid

    # Try to find root_source_file near this match (within 300 chars)
    after = build_zig[m.end():m.end() + 300]
    src_match = re.search(r'\.root_source_file\s*=\s*b\.path\("([^"]+)"\)', after)
    src_files = [src_match.group(1)] if src_match else []

    components.append({
        "id": cid,
        "name": name,
        "type": "executable",
        "programming_language": "zig",
        "source_files": src_files,
        "external_packages_ids": [],
        "depends_on_ids": [],
    })
    entrypoints.append(cid)

# Modules: addModule("name", .{ ... })
mod_re = re.compile(r'addModule\s*\(\s*"([^"]+)"')
for m in mod_re.finditer(build_zig):
    name = m.group(1)
    cid = make_id()
    key = (name, "module")
    comp_id_map[key] = cid

    # Source file is harder for modules — look for root_source_file
    after = build_zig[m.end():m.end() + 300]
    src_match = re.search(r'\.root_source_file\s*=\s*b\.path\("([^"]+)"\)', after)
    src_files = [src_match.group(1)] if src_match else []

    components.append({
        "id": cid,
        "name": name,
        "type": "package_library",
        "programming_language": "zig",
        "source_files": src_files,
        "external_packages_ids": [],
        "depends_on_ids": [],
    })

# Tests: addTest with .name = "..." or .root_source_file
test_re = re.compile(
    r'addTest\s*\(\s*\.\{\s*(?:.*?\s)?\.name\s*=\s*"([^"]+)"',
    re.DOTALL,
)
for m in test_re.finditer(build_zig):
    name = m.group(1)
    cid = make_id()
    key = (name, "test")
    comp_id_map[key] = cid
    components.append({
        "id": cid,
        "name": name,
        "type": "package_library",  # tests are library-like in the RIG model
        "programming_language": "zig",
        "source_files": [],
        "external_packages_ids": [],
        "depends_on_ids": [],
    })

# --- Parse internal dependencies from addImport calls ---
#
# Pattern: <consumer>.addImport("alias", <provider>)
# or:      <consumer>.root_module.addImport("alias", <provider>)
#
# The provider is usually a variable that was assigned from addModule/addExecutable.
# We also look for: b.dependency("name", ...) which links external deps.
import_re = re.compile(
    r'(\w+)\.root_module\.addImport\s*\(\s*"([^"]+)"\s*,\s*(\w+)\s*\)'
)
# Also match without root_module
import_re2 = re.compile(
    r'(\w+)\.addImport\s*\(\s*"([^"]+)"\s*,\s*(\w+)\s*\)'
)

# Build a map of variable name -> component id by scanning assignments
# e.g., const exe = b.addExecutable(...)
#       const mod = b.addModule(...)
var_to_comp = {}
assign_exe = re.compile(r'(?:const|var)\s+(\w+)\s*=\s*\S*addExecutable\s*\(\s*\.\{\s*(?:.*?\s)?\.name\s*=\s*"([^"]+)"', re.DOTALL)
for m in assign_exe.finditer(build_zig):
    var_to_comp[m.group(1)] = comp_id_map.get((m.group(2), "executable"))

assign_mod = re.compile(r'(?:const|var)\s+(\w+)\s*=\s*\S*addModule\s*\(\s*"([^"]+)"')
for m in assign_mod.finditer(build_zig):
    var_to_comp[m.group(1)] = comp_id_map.get((m.group(2), "module"))

# Also map bare addExecutable/addModule (not assigned to a var) — keyed by name
for key, cid in comp_id_map.items():
    name, ctype = key
    # Fallback: use the name as a pseudo-var (covers "exe", "mod" common patterns)
    pass

# Resolve import edges
for regex in (import_re, import_re2):
    for m in regex.finditer(build_zig):
        consumer_var, alias, provider_var = m.group(1), m.group(2), m.group(3)
        consumer_cid = var_to_comp.get(consumer_var)
        provider_cid = var_to_comp.get(provider_var)
        if consumer_cid and provider_cid and consumer_cid != provider_cid:
            for c in components:
                if c["id"] == consumer_cid:
                    if provider_cid not in c["depends_on_ids"]:
                        c["depends_on_ids"].append(provider_cid)
                    break

# --- Parse external packages from build.zig.zon ---
#
# .dependencies = .{
#     .foo = .{ .url = "...", .hash = "..." },
#     .bar = .{ .path = "vendor/bar" },
# }
#
# We extract the dependency names (the keys under .dependencies).
if build_zon_text:
    # Find the .dependencies block
    deps_match = re.search(r'\.dependencies\s*=\s*\.\{', build_zon_text)
    if deps_match:
        # Find matching closing brace (naive — ZON doesn't nest deeply in deps)
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

        # Extract dependency names: .name = .{
        for dm in re.finditer(r'\.(\w+)\s*=\s*\.\{', deps_block):
            dep_name = dm.group(1)
            eid = make_epid()
            ext_pkg_map[dep_name] = eid

            # Try to extract URL for package_manager info
            after_text = deps_block[dm.end():dm.end() + 500]
            url_match = re.search(r'\.url\s*=\s*"([^"]+)"', after_text)
            pkg_url = url_match.group(1) if url_match else ""

# Build external_packages list
external_packages = []
for name, eid in sorted(ext_pkg_map.items()):
    external_packages.append({
        "id": eid,
        "name": name,
        "package_manager": {
            "name": "zig-modules",
            "package_name": name,
        }
    })

# Link external deps to components that reference them via b.dependency("name", ...)
# or addImport with a known external name
dep_re = re.compile(r'b\.dependency\s*\(\s*"([^"]+)"')
for m in dep_re.finditer(build_zig):
    dep_name = m.group(1)
    eid = ext_pkg_map.get(dep_name)
    if eid:
        # Try to find which component uses this — look for addImport nearby
        after = build_zig[m.end():m.end() + 200]
        import_after = re.search(r'(\w+)\.root_module\.addImport\s*\(\s*"', after)
        if import_after:
            consumer_var = import_after.group(1)
            consumer_cid = var_to_comp.get(consumer_var)
            if consumer_cid:
                for c in components:
                    if c["id"] == consumer_cid and eid not in c["external_packages_ids"]:
                        c["external_packages_ids"].append(eid)
                        break

# Determine project name from build.zig.zon
project_name = "zig-project"
if build_zon_text:
    name_match = re.search(r'\.name\s*=\s*\.(\w+)', build_zon_text)
    if name_match:
        project_name = name_match.group(1)

git_ref = ""
if os.path.exists(".git"):
    try:
        r = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                           capture_output=True, text=True)
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

print(f"RIG: {len(components)} components, {len(external_packages)} external packages, {len(entrypoints)} entrypoints", file=sys.stderr)
PYEOF
