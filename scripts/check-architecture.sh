#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RUBY_BIN="/usr/bin/ruby"
CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-architecture.rb"

if [[ ! -x "${RUBY_BIN}" ]]; then
    printf 'Architecture checker requires executable %s\n' "${RUBY_BIN}" >&2
    exit 2
fi

if ! "${RUBY_BIN}" -rpsych -e 'exit(Psych.respond_to?(:parse_stream) ? 0 : 1)'; then
    printf 'Architecture checker requires Ruby stdlib Psych\n' >&2
    exit 2
fi

if ! command -v swift >/dev/null 2>&1; then
    printf 'Architecture checker requires Swift Package Manager on PATH\n' >&2
    exit 2
fi

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    printf 'Architecture checker requires xcrun and the Apple Swift compiler\n' >&2
    exit 2
fi

exec "${RUBY_BIN}" "${CHECKER}" "${ROOT_DIR}"
