#!/usr/bin/env bats
# The root.patched/post recipe of mk/turnkey.mk and mk/turnkey-desktop.mk,
# run by make rather than read: the step that writes the two identity files
# of an image (decision 0014) through bin/keel-version-files.
#
# fab is replaced by stubs under tests/mk/: an empty product.mk, a
# turnkey-version.py that prints the version string a build would derive,
# a make-release-deb.py and a fab-chroot that only log. What is real is the
# makefile text under test, make, bin/keel-version-files, and
# mk/turnkey/seal-hostname and mk/turnkey/seal-root, the next and the last
# step of the same recipe, reached through the FAB_PATH the recipe names
# them by; the scratch root ships root locked,
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
    ln -s "$ROOT/mk/turnkey/seal-hostname" "$FAB/common/mk/turnkey/seal-hostname"
    ln -s "$ROOT/mk/turnkey/install-debs" "$FAB/common/mk/turnkey/install-debs"
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

@test "turnkey.mk names the image after its appliance and drops the build's 127.0.1.1 line" {
    printf 'buildhost\n' > "$OUT/root.patched/etc/hostname"
    printf '127.0.0.1 localhost\n127.0.1.1 buildhost\n::1 localhost\n' > "$OUT/root.patched/etc/hosts"
    run_post turnkey.mk
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/root.patched/etc/hostname")" = core ]
    [ "$(cat "$OUT/root.patched/etc/hosts")" = "$(printf '127.0.0.1 localhost\n::1 localhost')" ]
}

@test "turnkey-desktop.mk names the image after its appliance too" {
    printf 'buildhost\n' > "$OUT/root.patched/etc/hostname"
    printf '127.0.1.1 buildhost\n' > "$OUT/root.patched/etc/hosts"
    run_post turnkey-desktop.mk
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/root.patched/etc/hostname")" = core ]
    [ ! -s "$OUT/root.patched/etc/hosts" ]
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

# python bytecode: the recipe precompiles it with
# timestamp invalidation, as Debian, Arch and Fedora do, and clamps the
# source mtimes to SOURCE_DATE_EPOCH so the result is reproducible. The
# fab-chroot stub only logs the command, so these assert the command text
# and its place in the recipe; the built image is verified separately.

@test "turnkey.mk precompiles python bytecode with timestamp invalidation" {
    run_post turnkey.mk
    [ "$status" -eq 0 ]
    [[ "$output" == *"compileall"* ]]
    [[ "$output" == *"--invalidation-mode=timestamp"* ]]
    [[ "$output" == *"/usr/lib/confconsole"* ]]
    [[ "$output" == *"/etc/python3.13"* ]]
}

@test "turnkey.mk precompiles after the product deb and before sealing root" {
    run_post turnkey.mk
    [ "$status" -eq 0 ]
    dpkg_line=$(printf '%s\n' "$output" | grep -n 'mk/turnkey/install-debs' | head -1 | cut -d: -f1)
    compile_line=$(printf '%s\n' "$output" | grep -n 'compileall' | head -1 | cut -d: -f1)
    [ -n "$dpkg_line" ]
    [ -n "$compile_line" ]
    [ "$compile_line" -gt "$dpkg_line" ]
}

@test "turnkey.mk does not precompile the test suites that packages ship" {
    run_post turnkey.mk
    [ "$status" -eq 0 ]
    line=$(printf '%s\n' "$output" | grep -m1 'compileall')
    [[ "$line" =~ -x\ \"([^\"]+)\" ]]
    regex="${BASH_REMATCH[1]}"
    # not under BATS_TEST_TMPDIR, whose path has a /test/ in it
    tree="$(mktemp -d /tmp/pyc.XXXXXX)/py"
    mkdir -p "$tree/pkg/tests/action_d" "$tree/pkg/test" "$tree/pkg/testing"
    : > "$tree/pkg/mod.py"
    : > "$tree/pkg/testing/mod.py"
    : > "$tree/pkg/tests/action_d/test_smtp.py"
    : > "$tree/pkg/test/test_a.py"
    python3 -m compileall -q -x "$regex" "$tree"
    ls "$tree"/pkg/__pycache__/mod.*.pyc
    ls "$tree"/pkg/testing/__pycache__/mod.*.pyc
    run find "$tree/pkg/tests" "$tree/pkg/test" -name '*.pyc'
    rm -rf "${tree%/py}"
    [ -z "$output" ]
}

@test "turnkey.mk clamps python mtimes to SOURCE_DATE_EPOCH for reproducibility" {
    run_post turnkey.mk
    [ "$status" -eq 0 ]
    [[ "$output" == *'touch -h -d "@$SOURCE_DATE_EPOCH"'* ]]
    [[ "$output" == *'[ -n "$SOURCE_DATE_EPOCH" ]'* ]]
    [[ "$output" == *'-name "*.pyc"'* ]]
}
