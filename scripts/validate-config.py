#!/usr/bin/env python3
"""Validate wiki.config.yml against the module's JSON Schema."""

import sys
import json
import yaml
from pathlib import Path


def resolve_schema():
    schema_path = Path(__file__).parent.parent / "schemas" / "wiki-config.schema.yaml"
    with open(schema_path) as f:
        schema = yaml.safe_load(f)
    return schema


def validate_config(config_path: str) -> list[str]:
    errors = []
    try:
        with open(config_path) as f:
            config = yaml.safe_load(f)
    except FileNotFoundError:
        return [f"Config file not found: {config_path}"]
    except yaml.YAMLError as e:
        return [f"Invalid YAML in {config_path}: {e}"]

    if config is None:
        return [f"Config file is empty: {config_path}"]

    schema = resolve_schema()

    try:
        import jsonschema
        jsonschema.validate(config, schema)
    except ImportError:
        errors = validate_manual(config, schema)
        if errors:
            return errors
        return []
    except jsonschema.ValidationError as e:
        return [f"Config validation error: {e.message} (at {'/'.join(str(p) for p in e.absolute_path)})"]

    return []


def validate_manual(config: dict, schema: dict) -> list[str]:
    errors = []
    required_top = schema.get("required", [])
    for key in required_top:
        if key not in config:
            errors.append(f"Missing required field: {key}")

    if "project" in config:
        proj = config["project"]
        if not isinstance(proj, dict):
            errors.append("project must be an object")
        else:
            for key in ["name", "title", "description"]:
                if key not in proj:
                    errors.append(f"Missing required field: project.{key}")
            if "name" in proj and not isinstance(proj.get("name"), str):
                errors.append("project.name must be a string")
            import re
            if "name" in proj and not re.match(r'^[a-z0-9][a-z0-9-]*$', proj.get("name", "")):
                errors.append("project.name must match ^[a-z0-9][a-z0-9-]*$")

    if "qmd" in config:
        qmd = config["qmd"]
        if not isinstance(qmd, dict):
            errors.append("qmd must be an object")
        elif "global_context" not in qmd:
            errors.append("Missing required field: qmd.global_context")

    if "arch" in config:
        arch = config["arch"]
        if not isinstance(arch, dict):
            errors.append("arch must be an object")
        else:
            projects = arch.get("projects", [])
            if not isinstance(projects, list) or len(projects) == 0:
                errors.append("arch.projects must be a non-empty array")
            else:
                import re as _re
                for i, p in enumerate(projects):
                    if not isinstance(p, dict):
                        errors.append(f"arch.projects[{i}] must be an object")
                        continue
                    for key in ("name", "rig_url"):
                        if key not in p:
                            errors.append(f"Missing required field: arch.projects[{i}].{key}")
                    if "name" in p and not _re.match(r'^[a-z0-9][a-z0-9-]*$', str(p.get("name", ""))):
                        errors.append(f"arch.projects[{i}].name must match ^[a-z0-9][a-z0-9-]*$")

    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: validate-config.py <wiki.config.yml>")
        sys.exit(1)

    config_path = sys.argv[1]
    errors = validate_config(config_path)

    if errors:
        print("=== Config Validation FAILED ===")
        for e in errors:
            print(f"  ERROR: {e}")
        sys.exit(1)
    else:
        print("Config validation passed.")
        sys.exit(0)


if __name__ == "__main__":
    main()
