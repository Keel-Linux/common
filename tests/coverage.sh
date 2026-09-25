#!/bin/bash
# Line coverage of conf/turnkey.d/postfix-local under the bats suite
# in this directory, measured with kcov. Exits 1 when the covered share of
# the script is below the threshold (default 95), 2 when a tool is missing.
#
#   tests/coverage.sh [THRESHOLD]
#
# COVERAGE_DIR keeps the kcov report (default: a temporary directory).
# Needs the Debian packages kcov and bats.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="$(cd "$here/.." && pwd)/conf/turnkey.d/postfix-local"
threshold="${1:-95}"

for tool in kcov bats; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not found (apt-get install $tool)" >&2
        exit 2
    fi
done

report="${COVERAGE_DIR:-$(mktemp -d)}"
kcov --include-path="$target" "$report" bats "$here"

# kcov names the sub directory after the command; with --include-path the
# report holds one file, so its first entry is ours
json="$(ls -t "$report"/*/coverage.json | grep -v /kcov-merged/ | head -1)"
percent="$(grep -o '"percent_covered": "[0-9.]*"' "$json" | head -1 | grep -o '[0-9.]*')"
covered="$(grep -o '"covered_lines": "[0-9]*"' "$json" | head -1 | grep -o '[0-9]*')"
total="$(grep -o '"total_lines": "[0-9]*"' "$json" | head -1 | grep -o '[0-9]*')"

echo "postfix-local: $percent percent ($covered of $total lines) covered, threshold $threshold"
if ! awk -v p="$percent" -v t="$threshold" 'BEGIN { exit !(p + 0 >= t + 0) }'; then
    echo "coverage below threshold (report: $report)" >&2
    exit 1
fi
