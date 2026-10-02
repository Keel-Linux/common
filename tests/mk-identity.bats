#!/usr/bin/env bats
# The root.patched/post recipe of mk/turnkey.mk and mk/turnkey-desktop.mk,
# run by make rather than read: the step that writes the two identity files
# of an image (decision 0014) through bin/keel-version-files.
#
# fab is replaced by stubs under tests/mk/: an empty product.mk, a
# turnkey-version.py that prints the version string a build would derive,
# a make-release-deb.py and a fab-chroot that only log. What is real is the
# makefile text under test, make, bin/keel-version-files, and
# mk/turnkey/seal-root, the last step of the same recipe, reached through
# the FAB_PATH the recipe names it by; the scratch root ships root locked,
# as an image must (common#31).

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STUBS="$BATS_TEST_DIRNAME/mk"
    WORK="$BATS_TEST_TMPDIR/product"
    OUT="$BATS_TEST_TMPDIR/build"
    FAB="$BATS_TEST_TMPDIR/fab"
    mkdir -p "$WORK" "$OUT/root.patched/etc/apt/apt.conf.d" "$FAB/common/mk/turnkey"
    ln -s "$ROOT/mk/turnkey/seal-root" "$FAB/common/mk/turnkey/seal-root"
    printf 'root:*:20718:0:99999:7:::\n' > "$OUT/root.patched/etc/shadow"
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
        FAB_PATH="$FAB" COMMON_BIN_PATH="$ROOT/bin" \
        CODENAME=trixie FAB_ARCH=amd64 "$@" post
}

@test "turnkey.mk writes both identity files" {
    run_post turnkey.mk
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/root.patched/etc/turnkey_version")" = turnkey-core-19.0-trixie-amd64 ]
    [ "$(cat "$OUT/root.patched/etc/keel_version")" = keel-core-19.0-trixie-amd64 ]
}

@test "turnkey.mk still seals root last: the build date is stamped after the identity files" {
    run_post turnkey.mk
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/root.patched/etc/keel/build-date")" = "$(date -u +%F)" ]
    [ -s "$OUT/root.patched/etc/keel_version" ]
}

@test "turnkey.mk writes no per-appliance apt User-Agent (common#6)" {
    # the identity files used to come with /etc/apt/apt.conf.d/01turnkey,
    # which told every archive which appliance this is; the overlay's 01keel
    # is the header now, and conf/turnkey.d/apt-identity removes a 01turnkey
    run_post turnkey.mk
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$OUT/root.patched/etc/apt/apt.conf.d")" ]
    run_post turnkey-desktop.mk
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$OUT/root.patched/etc/apt/apt.conf.d")" ]
}

@test "turnkey.mk: a root that ships a password fails the build after the identity files" {
    # a yescrypt field, literal: the $ are the hash's, not the shell's
    # shellcheck disable=SC2016
    printf 'root:$y$j9T$abcdefghijklmnop$qrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123:20718:0:99999:7:::\n' \
        > "$OUT/root.patched/etc/shadow"
    run_post turnkey.mk
    [ "$status" -ne 0 ]
    [[ "$output" == *"root has a password"* ]]
    [ ! -e "$OUT/root.patched/etc/keel/build-date" ]
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
