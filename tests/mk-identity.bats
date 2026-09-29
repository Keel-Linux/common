#!/usr/bin/env bats
# The root.patched/post recipe of mk/turnkey.mk and mk/turnkey-desktop.mk,
# run by make rather than read: the step that writes the two identity files
# of an image (decision 0014) through bin/keel-version-files.
#
# fab is replaced by stubs under tests/mk/: an empty product.mk, a
# turnkey-version.py that prints the version string a build would derive,
# a make-release-deb.py and a fab-chroot that only log. What is real is the
# makefile text under test, make, and bin/keel-version-files.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STUBS="$BATS_TEST_DIRNAME/mk"
    WORK="$BATS_TEST_TMPDIR/product"
    OUT="$BATS_TEST_TMPDIR/build"
    mkdir -p "$WORK" "$OUT/root.patched/etc/apt/apt.conf.d"
    : > "$WORK/changelog"
    export PATH="$STUBS:$PATH"
    export KEEL_TEST_RELEASE=turnkey-core-19.0-trixie-amd64
}

# run_post MAKEFILE [VAR=VALUE ...]: make the root.patched/post recipe of
# one of the two shared makefiles, from a product directory.
run_post() {
    local mk=$1
    shift
    run make --no-print-directory -C "$WORK" -f "$STUBS/harness.mk" \
        MK="$ROOT/mk/$mk" FAB_SHARE_PATH="$STUBS" O="$OUT" \
        FAB_PATH="$BATS_TEST_TMPDIR/fab" COMMON_BIN_PATH="$ROOT/bin" \
        CODENAME=trixie FAB_ARCH=amd64 "$@" post
}

@test "turnkey.mk writes both identity files" {
    run_post turnkey.mk
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/root.patched/etc/turnkey_version")" = turnkey-core-19.0-trixie-amd64 ]
    [ "$(cat "$OUT/root.patched/etc/keel_version")" = keel-core-19.0-trixie-amd64 ]
}

@test "turnkey-desktop.mk writes both identity files too" {
    run_post turnkey-desktop.mk
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/root.patched/etc/turnkey_version")" = turnkey-core-19.0-trixie-amd64 ]
    [ "$(cat "$OUT/root.patched/etc/keel_version")" = keel-core-19.0-trixie-amd64 ]
}

@test "a keel- changelog name still gives the compatibility file its prefix" {
    KEEL_TEST_RELEASE=keel-core-19.0-trixie-amd64 run_post turnkey.mk
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/root.patched/etc/turnkey_version")" = turnkey-core-19.0-trixie-amd64 ]
}

@test "turnkey.mk: a missing script stops the build and names the stale checkout" {
    run_post turnkey.mk COMMON_BIN_PATH="$BATS_TEST_TMPDIR/nowhere"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$BATS_TEST_TMPDIR/nowhere/keel-version-files"* ]]
    [[ "$output" == *"predates"* ]]
    [ ! -e "$OUT/root.patched/etc/turnkey_version" ]
}

@test "turnkey-desktop.mk: a missing script stops the build and names the stale checkout" {
    run_post turnkey-desktop.mk COMMON_BIN_PATH="$BATS_TEST_TMPDIR/nowhere"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$BATS_TEST_TMPDIR/nowhere/keel-version-files"* ]]
    [[ "$output" == *"predates"* ]]
}

@test "an empty version string is one argument, and is refused as a version" {
    KEEL_TEST_RELEASE="" run_post turnkey.mk
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not an appliance identity"* ]]
    [[ "$output" != *"two arguments are required"* ]]
}

@test "a version string with a space in it is one argument, and is refused as a version" {
    KEEL_TEST_RELEASE="turnkey-core 19.0-trixie-amd64" run_post turnkey.mk
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not an appliance identity"* ]]
}

@test "without a changelog nothing is written and the build goes on" {
    rm "$WORK/changelog"
    run_post turnkey.mk
    [ "$status" -eq 0 ]
    [[ "$output" == *"can't tag local release"* ]]
    [ ! -e "$OUT/root.patched/etc/keel_version" ]
}
