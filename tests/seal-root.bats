#!/usr/bin/env bats
# Tests for mk/turnkey/seal-root, the last step of root.patched: an image is
# exported with root locked, or the build fails, and it carries the date it
# was built on.
#
# Why: inithooks' first boot offers to keep a root password set when the
# container was created (pct create --password). It can only tell such a
# password from one the image shipped if the image shipped none, and five
# older WordPress images shipped U6aMy0wojraho, the crypt() of the empty
# string; a build with ROOT_PASS set shipped a password every copy shares.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../mk/turnkey/seal-root"
    ROOTFS=$BATS_TEST_TMPDIR/rootfs
    mkdir -p "$ROOTFS/etc"
}

# shadow_root FIELD
# A shadow file whose root entry has password field FIELD.
shadow_root() {
    printf 'daemon:*:20718:0:99999:7:::\nroot:%s:20718:0:99999:7:::\n' \
        "$1" > "$ROOTFS/etc/shadow"
}

@test "a root field of '*' passes and the build date is stamped" {
    shadow_root '*'

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/keel/build-date")" = "$(date -u +%F)" ]
}

@test "a root field of '!' passes" {
    shadow_root '!'

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
}

@test "a root field of '!*', what passwd --lock makes of '*', passes" {
    shadow_root '!*'

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 0 ]
}

@test "a real password hash fails the build and is not printed" {
    shadow_root '$y$j9T$abcdefghijklmnop$qrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123'

    run --separate-stderr "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "${stderr:-}" == *"root has a password"* ]]
    [[ "$output${stderr:-}" != *'$y$'* ]]
    [ ! -e "$ROOTFS/etc/keel/build-date" ]
}

@test "the hash of the empty password fails the build" {
    shadow_root 'U6aMy0wojraho'

    run --separate-stderr "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "$output${stderr:-}" != *U6aMy0wojraho* ]]
}

@test "an empty field, which lets anyone in, fails the build" {
    shadow_root ''

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
}

@test "a locked real hash fails too: unlocking it gives the password back" {
    shadow_root '!$y$j9T$abcdefghijklmnop$qrstuvwxyz'

    run "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
}

@test "a shadow file with no root entry fails the build" {
    printf 'daemon:*:20718:0:99999:7:::\n' > "$ROOTFS/etc/shadow"

    run --separate-stderr "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "${stderr:-}" == *"no root entry"* ]]
}

@test "a root file system without a shadow file fails the build" {
    run --separate-stderr "$SCRIPT" "$ROOTFS"

    [ "$status" -eq 1 ]
    [[ "${stderr:-}" == *"cannot read"* ]]
}

@test "the appliance build seals root.patched as the last step of its post hook" {
    local mk=$TESTS_DIR/../mk/turnkey.mk
    local hook
    hook=$(sed -n '/^define _root.patched\/post/,/^endef/p' "$mk")
    last=$(grep -v '^[[:space:]]*\(#.*\)\?$' <<< "$hook" | tail -2 | head -1)
    [[ "$last" == *'common/mk/turnkey/seal-root $O/root.patched' ]]
}

@test "no root file system given is a usage error" {
    run "$SCRIPT"

    [ "$status" -eq 2 ]
}
