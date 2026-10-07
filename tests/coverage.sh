#!/bin/bash
# Line coverage of the shell this repository is measured on, with kcov
# (decision 0004). Exits 1 when any measured file is below the threshold
# (default 95, the bar for project-authored code), 2 when a tool is missing.
#
#   tests/coverage.sh [THRESHOLD]     (or COVERAGE_THRESHOLD in the environment)
#
# COVERAGE_DIR keeps the kcov reports, one directory per measured file
# (default: a temporary directory). Needs the Debian packages kcov and bats;
# tests/apt-identity.bats also needs apt, openssl and python3, and
# tests/dpkg-vendor.bats needs dpkg-vendor from dpkg-dev.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
threshold="${1:-${COVERAGE_THRESHOLD:-95}}"

# Each entry is a measured file and the bats file that exercises it.
targets=(
    "conf/turnkey.d/postfix-local:tests/postfix-local.bats"
    "conf/turnkey.d/locale:tests/locale.bats"
    "conf/turnkey.d/dpkg-vendor:tests/dpkg-vendor.bats"
    "conf/turnkey.d/apt-identity:tests/apt-identity.bats"
    "conf/turnkey.d/keel-apt:tests/apt-sources.bats"
    "conf/samba-rootpass:tests/samba-rootpass.bats"
    "conf/pgsql:tests/pgsql-conf.bats"
    "conf/mysql:tests/mysql-conf.bats"
    "conf/desktop:tests/desktop.bats"
    "conf/turnkey.d/rootpass:tests/rootpass.bats"
    "mk/turnkey/seal-root:tests/seal-root.bats"
    "mk/turnkey/seal-hostname:tests/seal-hostname.bats"
    "conf/turnkey.d/webmin-enable:tests/webmin-enable.bats"
    "conf/turnkey.d/webmin-pam:tests/webmin-pam.bats"
    "conf/turnkey.d/webmin-net:tests/webmin-net.bats"
    "conf/turnkey.d/webmin-theme:tests/webmin-brand.bats"
    "conf/turnkey.d/webmin-defmodule:tests/webmin-brand.bats"
    "conf/turnkey.d/motd:tests/motd.bats"
    "conf/turnkey.d/container-units:tests/container-units.bats"
    "overlays/turnkey.d/webmin-net/usr/local/sbin/webmin-net-read-only:tests/webmin-net.bats"
    "overlays/turnkey.d/resolvconf-ifupdown-ng/etc/network/if-up.d/000resolvconf-ifupdown-ng:tests/resolvconf-ifupdown-ng.bats"
    "overlays/turnkey.d/resolvconf-ifupdown-ng/etc/network/if-down.d/resolvconf-ifupdown-ng:tests/resolvconf-ifupdown-ng.bats"
    "packages/coraza/state:tests/coraza-state.bats"
    "packages/anubis/signing-key:tests/anubis-signing-key.bats"
    "lib/version-files.sh:tests/version-files.bats"
    "bin/keel-version-files:tests/version-files.bats"
)

for tool in kcov bats; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not found (apt-get install $tool)" >&2
        exit 2
    fi
done

reports="${COVERAGE_DIR:-$(mktemp -d)}"
failed=0

for target in "${targets[@]}"; do
    measured="${target%%:*}"
    suite="${target#*:}"
    name="$(basename "$measured")"
    report="$reports/$name"
    mkdir -p "$report"
    kcov --include-path="$root/$measured" "$report" bats "$root/$suite"

    # with --include-path the report holds one file, so its first entry is ours
    json="$(find "$report" -name coverage.json -not -path '*/kcov-merged/*' | head -1)"
    percent="$(grep -o '"percent_covered": "[0-9.]*"' "$json" | head -1 | grep -o '[0-9.]*')"
    covered="$(grep -o '"covered_lines": "[0-9]*"' "$json" | head -1 | grep -o '[0-9]*')"
    total="$(grep -o '"total_lines": "[0-9]*"' "$json" | head -1 | grep -o '[0-9]*')"

    echo "$name: $percent percent ($covered of $total lines) covered, threshold $threshold"
    if ! awk -v p="$percent" -v t="$threshold" 'BEGIN { exit !(p + 0 >= t + 0) }'; then
        echo "$name: coverage below threshold (report: $report)" >&2
        failed=1
    fi
done

# Suites that measure no file of their own still have to pass:
# before-firstboot.bats runs rootpass, webmin-enable and webmin-pam together,
# and pam-unix.bats pins the pam_unix behaviour the others rest on.
bats "$root/tests/before-firstboot.bats" "$root/tests/pam-unix.bats"

# Suites whose subject kcov cannot measure: the make recipes of mk/, run by
# make against stubs of fab. They must pass; they contribute no percentage.
unmeasured=(
    tests/mk-identity.bats
)
for suite in "${unmeasured[@]}"; do
    if ! bats "$root/$suite"; then
        echo "$suite: failed" >&2
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    exit 1
fi
