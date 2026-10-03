#!/usr/bin/env bats
# Tests for mk/turnkey/seal-hostname, run in root.patched/post after the
# identity files: an image is exported named after its appliance and with
# no 127.0.1.1 line in /etc/hosts, so that the first boot (inithooks'
# 09hostname and 31fqdn) is the only writer of the machine's name.
#
# Why: conf/turnkey.d/hostname writes the build's HOSTNAME into
# /etc/hostname and "127.0.1.1 $HOSTNAME" into /etc/hosts, and a Keel Web
# container created by pct carried both that "127.0.1.1 web" and pct's own
# "127.0.1.1 keel-web1.pop.coop keel-web1" (2026-10-03).

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../mk/turnkey/seal-hostname"
    ROOTFS=$BATS_TEST_TMPDIR/rootfs
    mkdir -p "$ROOTFS/etc"
}

# identity VERSION [FILE]
# An identity file (keel_version unless FILE says otherwise) naming VERSION.
identity() {
    printf '%s\n' "$1" > "$ROOTFS/etc/${2:-keel_version}"
}

# build_hosts NAME
# The /etc/hosts conf/turnkey.d/hostname writes for a build named NAME.
build_hosts() {
    cat > "$ROOTFS/etc/hosts" <<HOSTS
127.0.0.1 localhost
127.0.1.1 $1

#Required for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
HOSTS
}

@test "the hostname is the appliance name of /etc/keel_version" {
    identity keel-web-19.0-trixie-amd64
    printf 'buildhost\n' > "$ROOTFS/etc/hostname"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/hostname")" = web ]
}

@test "an appliance name with hyphens is kept whole" {
    identity keel-nginx-php-fastcgi-19.0-trixie-amd64

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/hostname")" = nginx-php-fastcgi ]
}

@test "/etc/turnkey_version names the appliance when the Keel file is missing" {
    identity turnkey-core-19.0-trixie-amd64 turnkey_version

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/hostname")" = core ]
}

@test "the hostname file is world readable, as hostname(1) needs it" {
    identity keel-web-19.0-trixie-amd64

    run "$SCRIPT" "$ROOTFS"

    [ "$(stat -c %a "$ROOTFS/etc/hostname")" = 644 ]
}

@test "the build's 127.0.1.1 line leaves /etc/hosts and every other line stays" {
    identity keel-web-19.0-trixie-amd64
    build_hosts web

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    run grep -c '127\.0\.1\.1' "$ROOTFS/etc/hosts"
    [ "$status" -eq 1 ]
    [ "$(sed -n 1p "$ROOTFS/etc/hosts")" = "127.0.0.1 localhost" ]
    [ "$(sed -n 2p "$ROOTFS/etc/hosts")" = "" ]
    grep -qx '::1 ip6-localhost ip6-loopback' "$ROOTFS/etc/hosts"
    grep -qx 'ff02::3 ip6-allhosts' "$ROOTFS/etc/hosts"
    [ "$(wc -l < "$ROOTFS/etc/hosts")" -eq 9 ]
}

@test "every 127.0.1.1 line goes, whatever names and spacing it carries" {
    identity keel-web-19.0-trixie-amd64
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tweb\n  127.0.1.1 keel-web1.pop.coop keel-web1\n::1 localhost\n' \
        > "$ROOTFS/etc/hosts"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/hosts")" = "$(printf '127.0.0.1\tlocalhost\n::1 localhost')" ]
}

@test "a line that only begins like 127.0.1.1 is not a 127.0.1.1 line" {
    identity keel-web-19.0-trixie-amd64
    printf '127.0.1.10 tenth\n127.0.1.1 web\n' > "$ROOTFS/etc/hosts"

    run "$SCRIPT" "$ROOTFS"

    [ "$(cat "$ROOTFS/etc/hosts")" = "127.0.1.10 tenth" ]
}

@test "the mode of /etc/hosts is kept" {
    identity keel-web-19.0-trixie-amd64
    build_hosts web
    chmod 0644 "$ROOTFS/etc/hosts"

    run "$SCRIPT" "$ROOTFS"

    [ "$(stat -c %a "$ROOTFS/etc/hosts")" = 644 ]
}

@test "a root file system without /etc/hosts gets its hostname and no hosts file" {
    identity keel-web-19.0-trixie-amd64

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/hostname")" = web ]
    [ ! -e "$ROOTFS/etc/hosts" ]
}

@test "the build log says what was written and what was dropped" {
    identity keel-web-19.0-trixie-amd64
    build_hosts web

    run "$SCRIPT" "$ROOTFS"

    [[ "$output" == *"/etc/hostname: web"* ]]
    [[ "$output" == *"127.0.1.1"* ]]
}

@test "without an identity file the build fails and names what is missing" {
    build_hosts web

    run --separate-stderr "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "${stderr:-}" == *"keel_version"* ]]
    grep -q '127.0.1.1 web' "$ROOTFS/etc/hosts"
}

@test "an identity string that is not an appliance identity fails the build" {
    identity core

    run --separate-stderr "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "${stderr:-}" == *"not an appliance identity"* ]]
    [ ! -e "$ROOTFS/etc/hostname" ]
}

@test "an unwritable tree fails the build" {
    identity keel-web-19.0-trixie-amd64
    chmod 0555 "$ROOTFS/etc"

    run --separate-stderr "$SCRIPT" "$ROOTFS"

    chmod 0755 "$ROOTFS/etc"
    [ "$status" -eq 2 ]
    [[ "${stderr:-}" == *"cannot write"* ]]
}

@test "a hosts file with no 127.0.1.1 line is left as it is" {
    identity keel-web-19.0-trixie-amd64
    printf '127.0.0.1 localhost\n::1 localhost\n' > "$ROOTFS/etc/hosts"

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/hosts")" = "$(printf '127.0.0.1 localhost\n::1 localhost')" ]
    [[ "$output" != *dropped* ]]
}

@test "a common checkout without the library stops the build naming it" {
    identity keel-web-19.0-trixie-amd64

    SEAL_HOSTNAME_LIB=$BATS_TEST_TMPDIR/nowhere run --separate-stderr "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 3 ]
    [[ "${stderr:-}" == *"version-files.sh"* ]]
}

@test "no root file system given is a usage error" {
    run "$SCRIPT"

    [ "$status" -eq 2 ]
}

@test "the appliance build seals the name after the identity files and before root" {
    local mk hook
    for mk in "$TESTS_DIR/../mk/turnkey.mk" "$TESTS_DIR/../mk/turnkey-desktop.mk"; do
        hook=$(sed -n '/^define _root.patched\/post/,/^endef/p' "$mk")
        [[ "$hook" == *'keel-version-files "$$release_version" $O/root.patched'*'common/mk/turnkey/seal-hostname $O/root.patched'* ]]
    done
    hook=$(sed -n '/^define _root.patched\/post/,/^endef/p' "$TESTS_DIR/../mk/turnkey.mk")
    [[ "$hook" == *'seal-hostname $O/root.patched'*'seal-root $O/root.patched'* ]]
}
