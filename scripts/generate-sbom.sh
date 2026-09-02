#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

case "${1:-}" in
  --verify-clean)
    exec ruby "$repo_root/scripts/generate-sbom.rb" --check
    ;;
  "")
    exec ruby "$repo_root/scripts/generate-sbom.rb"
    ;;
  *)
    echo "usage: $0 [--verify-clean]" >&2
    exit 64
    ;;
esac
