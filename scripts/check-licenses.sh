#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$repo_root/scripts/generate-sbom.sh" --verify-clean
exec ruby "$repo_root/scripts/check-licenses.rb"
