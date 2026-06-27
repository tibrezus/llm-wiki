#!/usr/bin/env bash
# Portable Python dependency installer for CI runners.
#
# Usage: install-python-deps.sh [package ...]
# Default packages: pyyaml
#
# Why this exists: CI runners vary wildly. Some ship system Python with no pip
# (`No module named pip`), some are externally-managed (PEP 668), some only have
# distro package managers (apt/dnf/apk). A bare `python3 -m pip install` is not
# portable. This script tries, in order:
#   1. already-importable -> nothing to do
#   2. pip (--user, then --break-system-packages, then bare)
#   3. distro packages (apt / dnf / apk) with sudo when available
#   4. bootstrap pip via get-pip.py and retry pip
#   5. fail loudly if still missing
#
# Designed to run on GitHub Actions, Forgejo/Gitea Actions, GitLab CI, and bare
# self-hosted runners, across Debian/Ubuntu, Fedora/RHEL, and Alpine.

set -uo pipefail

pkgs=("$@")
[ "${#pkgs[@]}" -eq 0 ] && pkgs=(pyyaml)

# Map import-name -> pip/distro names where they differ.
import_check="${pkgs[0]}"                 # e.g. pyyaml -> import yaml
case "$import_check" in
  pyyaml) import_name="yaml" ;;
  *)      import_name="$import_check" ;;
esac

have() { python3 -c "import $1" 2>/dev/null; }

if have "$import_name"; then
  echo "[install-python-deps] $import_name already importable; nothing to do"
  exit 0
fi

pip_pkgs="${pkgs[*]}"

echo "[install-python-deps] need: $pip_pkgs (import $import_name)"

# 1) pip variants (works on most GitHub-hosted + many self-hosted runners)
echo "[install-python-deps] trying pip..."
python3 -m pip install --user $pip_pkgs 2>/dev/null \
  || python3 -m pip install --break-system-packages $pip_pkgs 2>/dev/null \
  || python3 -m pip install $pip_pkgs 2>/dev/null \
  || true

if have "$import_name"; then
  echo "[install-python-deps] installed via pip"; exit 0
fi

# 2) distro package managers (Debian/Ubuntu, Fedora/RHEL, Alpine)
sudo_cmd=""
if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
  sudo_cmd="sudo"
fi

if command -v apt-get >/dev/null 2>&1; then
  echo "[install-python-deps] trying apt..."
  # Map: pyyaml -> python3-yaml, jsonschema -> python3-jsonschema
  apt_pkgs=""
  for p in "${pkgs[@]}"; do
    case "$p" in
      pyyaml)    apt_pkgs="$apt_pkgs python3-yaml" ;;
      jsonschema) apt_pkgs="$apt_pkgs python3-jsonschema" ;;
      *)         apt_pkgs="$apt_pkgs python3-$p" ;;
    esac
  done
  $sudo_cmd apt-get update -qq 2>/dev/null || true
  $sudo_cmd apt-get install -y -qq $apt_pkgs 2>/dev/null || $sudo_cmd apt-get install -y -qq python3-yaml 2>/dev/null || true
elif command -v dnf >/dev/null 2>&1; then
  echo "[install-python-deps] trying dnf..."
  dnf_pkgs=""
  for p in "${pkgs[@]}"; do
    case "$p" in
      pyyaml)     dnf_pkgs="$dnf_pkgs python3-pyyaml" ;;
      jsonschema) dnf_pkgs="$dnf_pkgs python3-jsonschema" ;;
      *)          dnf_pkgs="$dnf_pkgs python3-$p" ;;
    esac
  done
  $sudo_cmd dnf install -y $dnf_pkgs 2>/dev/null || $sudo_cmd dnf install -y python3-pyyaml 2>/dev/null || true
elif command -v apk >/dev/null 2>&1; then
  echo "[install-python-deps] trying apk..."
  apk_pkgs=""
  for p in "${pkgs[@]}"; do
    case "$p" in
      pyyaml)     apk_pkgs="$apk_pkgs py3-yaml" ;;
      jsonschema) apk_pkgs="$apk_pkgs py3-jsonschema" ;;
      *)          apk_pkgs="$apk_pkgs py3-$p" ;;
    esac
  done
  $sudo_cmd apk add --no-cache $apk_pkgs 2>/dev/null || true
fi

if have "$import_name"; then
  echo "[install-python-deps] installed via distro packages"; exit 0
fi

# 3) bootstrap pip (system Python without pip, e.g. stock Debian images)
echo "[install-python-deps] trying get-pip.py bootstrap..."
if command -v curl >/dev/null 2>&1; then
  if curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py 2>/dev/null; then
    python3 /tmp/get-pip.py --user --break-system-packages 2>/dev/null \
      || python3 /tmp/get-pip.py --user 2>/dev/null \
      || python3 /tmp/get-pip.py 2>/dev/null \
      || true
    python3 -m pip install --user --break-system-packages $pip_pkgs 2>/dev/null \
      || python3 -m pip install --user $pip_pkgs 2>/dev/null \
      || python3 -m pip install --break-system-packages $pip_pkgs 2>/dev/null \
      || true
  fi
fi

if have "$import_name"; then
  echo "[install-python-deps] installed via get-pip.py"; exit 0
fi

echo "::error::Failed to install Python packages: $pip_pkgs (could not import '$import_name')"
exit 1
