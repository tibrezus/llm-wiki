#!/usr/bin/env bash
set -euo pipefail

# RIG emitter for Go projects.
# Uses `go list -json` (native, deterministic) to discover packages,
# their imports, and their types. Produces a RIG JSON conforming to
# schemas/repo-map.schema.yaml.
#
# Usage: emit-go.sh <output.json>

OUT="${1:?Usage: emit-go.sh <output.json>}"

# Verify go is available.
command -v go >/dev/null 2>&1 || { echo "::error::go not found on PATH"; exit 1; }

MODULE_PATH=$(go list -m 2>/dev/null | awk '{print $1}') || {
  echo "::error::Not a Go module (no go.mod?)"; exit 1; }

python3 - "$OUT" "$MODULE_PATH" <<'PYEOF'
import json, subprocess, sys, os, re
from datetime import datetime, timezone

out_path = sys.argv[1]
module_path = sys.argv[2]

def go_list_json(pattern):
    # -e: continue despite per-package errors (missing deps, etc.)
    r = subprocess.run(
        ["go", "list", "-e", "-json", pattern],
        capture_output=True, text=True
    )
    # Even with -e, go list may exit non-zero but still output valid JSON.
    if not r.stdout.strip():
        return []
    # `go list -json` outputs multiple JSON objects concatenated.
    decoder = json.JSONDecoder()
    objs = []
    text = r.stdout.strip()
    idx = 0
    while idx < len(text):
        text_slice = text[idx:].lstrip()
        if not text_slice:
            break
        obj, consumed = decoder.raw_decode(text_slice)
        objs.append(obj)
        idx = len(text) - len(text_slice) + consumed
    return objs

packages = go_list_json("./...")
if not packages:
    print("::error::go list returned no packages", file=sys.stderr)
    sys.exit(1)

# Classify packages.
components = []
comp_id_map = {}  # import_path -> id
ext_pkg_map = {}  # name -> id
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

entrypoints = []

for pkg in packages:
    import_path = pkg.get("ImportPath", "")
    if not import_path:
        continue

    name = import_path.split("/")[-1] if "/" in import_path else import_path
    is_main = pkg.get("Name") == "main"

    cid = make_id()
    comp_id_map[import_path] = cid

    # Source files (relative to module root).
    go_files = pkg.get("GoFiles", []) or []
    src_files = [os.path.join(pkg.get("Dir", ""), f).replace(os.getcwd() + "/", "")
                 for f in go_files]

    # External dependencies (non-stdlib imports).
    imports = pkg.get("Imports", []) or []
    ext_refs = []
    for imp in imports:
        if imp.startswith(module_path):
            continue
        # Heuristic: stdlib packages don't contain a dot in the first segment.
        first = imp.split("/")[0]
        if "." not in first:
            continue  # stdlib
        if imp not in ext_pkg_map:
            ext_pkg_map[imp] = make_epid()
        ext_refs.append(ext_pkg_map[imp])

    components.append({
        "id": cid,
        "name": name,
        "type": "executable" if is_main else "package_library",
        "programming_language": "go",
        "source_files": src_files[:20],  # cap for size
        "external_packages_ids": ext_refs,
        "depends_on_ids": [],  # filled in second pass
    })

    if is_main:
        entrypoints.append(cid)

# Second pass: resolve internal dependencies (depends_on_ids).
for pkg in packages:
    src_import = pkg.get("ImportPath", "")
    if src_import not in comp_id_map:
        continue
    imports = pkg.get("Imports", []) or []
    deps = []
    for imp in imports:
        if imp.startswith(module_path) and imp != src_import and imp in comp_id_map:
            deps.append(comp_id_map[imp])
    # Find the component we just created and set its deps.
    for c in components:
        if c["id"] == comp_id_map[src_import]:
            c["depends_on_ids"] = list(set(deps))
            break

# Build external_packages list.
external_packages = []
for name, eid in sorted(ext_pkg_map.items()):
    external_packages.append({
        "id": eid,
        "name": name,
        "package_manager": {
            "name": "go-modules",
            "package_name": name,
        }
    })

rig = {
    "schema_version": "rig-1.0",
    "repository": {
        "name": module_path.split("/")[-1],
        "ref": subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True
        ).stdout.strip() if os.path.exists(".git") else "",
        "language": "go",
        "build_system": "go-modules",
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
