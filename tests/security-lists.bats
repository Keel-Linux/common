#!/usr/bin/env bats
# Tests for overlays/turnkey.d/security-lists: the monit rule and
# usr/local/sbin/keel-security-lists-age, which says when Debian's security
# index has not been fetched for three days (cron-apt then installs no fix
# and, with mail off, tells no one).
#
# logger and ip are stubs that record what they get. The InRelease files are
# fixtures with the Date line the real ones carry.
#
# Refutations are "run !", never a bare "!" (docs/traps.md).

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO="$(cd "$TESTS_DIR/.." && pwd)"
    OVERLAY="$REPO/overlays/turnkey.d/security-lists"
    CHECK="$OVERLAY/usr/local/sbin/keel-security-lists-age"

    export KEEL_SECURITY_LISTS="$BATS_TEST_TMPDIR/lists"
    export KEEL_SECURITY_FIRST_BOOT="$BATS_TEST_TMPDIR/machine-id"
    export KEEL_SECURITY_RESOLV_CONF="$BATS_TEST_TMPDIR/resolv.conf"
    export KEEL_SECURITY_NOW=1793000000
    mkdir -p "$KEEL_SECURITY_LISTS" "$BATS_TEST_TMPDIR/bin"
    printf 'nameserver 2001:db8::53\n' > "$KEEL_SECURITY_RESOLV_CONF"
    : > "$KEEL_SECURITY_FIRST_BOOT"
    touch -d "@$KEEL_SECURITY_NOW" "$KEEL_SECURITY_FIRST_BOOT"

    cat > "$BATS_TEST_TMPDIR/bin/logger" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/logger"
exit \${LOGGER_EXIT:-0}
STUB
    cat > "$BATS_TEST_TMPDIR/bin/ip" <<STUB
#!/bin/sh
[ -n "\${IPV4_ROUTE:-}" ] && echo "default via 192.0.2.1 dev eth0"
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# release HOURS_OLD [NAME]: a security InRelease signed HOURS_OLD hours ago
release() {
    local name="${2:-security.debian.org_debian-security_dists_trixie-security_InRelease}"
    printf 'Origin: Debian\nSuite: stable-security\nDate: %s\n' \
        "$(date -u -R -d "@$((KEEL_SECURITY_NOW - $1 * 3600))")" > "$KEEL_SECURITY_LISTS/$name"
}

@test "a security index fetched an hour ago passes" {
    release 1
    run "$CHECK"
    [ "$status" -eq 0 ]
    [ "$output" = "security index: 1 h old" ]
    [ ! -e "$BATS_TEST_TMPDIR/logger" ]
}

@test "a security index older than three days fails, on standard output and the system log" {
    release 73
    run "$CHECK"
    [ "$status" -eq 1 ]
    [ "$output" = "security index: 73 h old, cron-apt installs no fix" ]
    grep -qx -- "-p user.err -t keel-security-lists security index: 73 h old, cron-apt installs no fix" "$BATS_TEST_TMPDIR/logger"
}

@test "the newest of the security indices counts" {
    release 100
    release 2 deb.debian.org_debian-security_dists_trixie-security_InRelease
    run "$CHECK"
    [ "$status" -eq 0 ]
    [ "$output" = "security index: 2 h old" ]
}

@test "an index with no readable Date is left out" {
    printf 'Origin: Debian\nDate: not a date\n' \
        > "$KEEL_SECURITY_LISTS/security.debian.org_debian-security_dists_trixie-security_InRelease"
    release 1 deb.debian.org_debian-security_dists_trixie-security_InRelease
    run "$CHECK"
    [ "$status" -eq 0 ]
    [ "$output" = "security index: 1 h old" ]
}

@test "the age limit is KEEL_SECURITY_MAX_AGE seconds" {
    release 5
    KEEL_SECURITY_MAX_AGE=3600 run "$CHECK"
    [ "$status" -eq 1 ]
}

@test "a fresh machine that has not fetched the index yet passes" {
    touch -d "@$((KEEL_SECURITY_NOW - 3600))" "$KEEL_SECURITY_FIRST_BOOT"
    run "$CHECK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a machine that never fetched the index in three days fails" {
    touch -d "@$((KEEL_SECURITY_NOW - 80 * 3600))" "$KEEL_SECURITY_FIRST_BOOT"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [ "$output" = "security index: never fetched in 80 h, cron-apt installs no fix" ]
}

@test "an IPv4 name server on a machine with no IPv4 route is named as the likely cause" {
    release 90
    printf 'nameserver 1.1.1.1\n' > "$KEEL_SECURITY_RESOLV_CONF"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"; every name server in $KEEL_SECURITY_RESOLV_CONF is IPv4 and there is no IPv4 route: set an IPv6 name server (pct set <id> --nameserver)" ]]
}

@test "an IPv4 name server with an IPv4 route is not blamed" {
    release 90
    printf 'nameserver 1.1.1.1\n' > "$KEEL_SECURITY_RESOLV_CONF"
    IPV4_ROUTE=1 run "$CHECK"
    [ "$status" -eq 1 ]
    [ "$output" = "security index: 90 h old, cron-apt installs no fix" ]
}

@test "no name server at all is said" {
    release 90
    : > "$KEEL_SECURITY_RESOLV_CONF"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [ "$output" = "security index: 90 h old, cron-apt installs no fix; no name server in $KEEL_SECURITY_RESOLV_CONF" ]
}

@test "a failing logger does not change the verdict" {
    release 90
    LOGGER_EXIT=1 run "$CHECK"
    [ "$status" -eq 1 ]
    [ "$output" = "security index: 90 h old, cron-apt installs no fix" ]
}

@test "monit runs the check every hour and alerts when it fails" {
    local rule="$OVERLAY/etc/monit/conf.d/security-lists"
    grep -qx 'check program security-lists with path /usr/local/sbin/keel-security-lists-age' "$rule"
    grep -qx '  every 30 cycles' "$rule"
    grep -qx '  if status != 0 then alert' "$rule"
    [ -x "$CHECK" ]
}
