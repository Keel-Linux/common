#!/bin/bash
# Line coverage of the conf scripts this repository has tests for, measured
# with kcov over the bats suite in this directory. Exits 1 when any measured
# file is below the threshold (default 95), 2 when a tool is missing.
#
#   tests/coverage.sh [THRESHOLD]     (or COVERAGE_THRESHOLD in the environment)
#
# COVERAGE_DIR keeps the kcov report (default: a temporary directory).
# Needs the Debian packages kcov and bats.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
threshold="${1:-${COVERAGE_THRESHOLD:-95}}"

# Every file the suite is expected to cover. A file that is not listed is
# not measured, so a new script arrives here with its tests.
measured=(
    conf/samba-rootpass
    conf/turnkey.d/postfix-local
    conf/turnkey.d/rootpass
    conf/turnkey.d/webmin-enable
    conf/turnkey.d/webmin-pam
)

for tool in kcov bats; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not found (apt-get install $tool)" >&2
        exit 2
    fi
done

include=""
for file in "${measured[@]}"; do
    if [[ ! -f "$repo/$file" ]]; then
        echo "measured file is missing: $file" >&2
        exit 2
    fi
    include="${include:+$include,}$repo/$file"
done

report="${COVERAGE_DIR:-$(mktemp -d)}"
kcov --include-path="$include" "$report" bats "$here"

json="$(find "$report" -name coverage.json -not -path '*/kcov-merged/*' | head -1)"
if [[ -z "$json" ]]; then
    echo "coverage.sh: no coverage.json under $report" >&2
    exit 1
fi

# kcov writes one line per measured file:
#   {"file": "PATH", "percent_covered": "P", "covered_lines": "C", ...},
echo
echo "kcov line coverage (threshold $threshold percent):"
awk -F'"' -v threshold="$threshold" -v repo="$repo/" -v want="${#measured[@]}" '
    /^ *\{"file":/ {
        file = $4
        sub(repo, "", file)
        percent = $8 + 0
        seen++
        mark = (percent >= threshold) ? "ok" : "BELOW THRESHOLD"
        if (percent < threshold) {
            low = 1
        }
        printf "%7.2f  %4s/%-4s  %-32s %s\n", percent, $12, $16, file, mark
    }
    /^  "percent_covered":/ {
        printf "%7.2f  total\n", $4 + 0
    }
    END {
        if (seen != want) {
            printf "measured %d files, expected %d\n", seen, want > "/dev/stderr"
            exit 1
        }
        exit low
    }' "$json"
