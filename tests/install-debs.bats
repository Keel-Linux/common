#!/usr/bin/env bats
# Tests for mk/turnkey/install-debs, run in root.patched/post: it installs
# the .deb files of a product in the root of the image and removes them.
#
# Why: the recipe passed "*.deb" to dpkg unexpanded when there was none, so
# every build logged "dpkg: error: cannot access archive '*.deb'", and fab
# 1.1.1 exits 0 from a command string, so a real dpkg failure did not stop
# the build (common#73).
#
# fab-chroot is a stub on PATH. FAKE_DPKG says what the stub's dpkg does:
# "ok" removes the .deb files as dpkg -i && rm does, "fail" leaves them.
# The stub always exits 0, as fab 1.1.1 does. FAKE_FAB=fail makes it exit 1.

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../mk/turnkey/install-debs"
    ROOTFS=$BATS_TEST_TMPDIR/rootfs
    STUB=$BATS_TEST_TMPDIR/bin
    mkdir -p "$ROOTFS" "$STUB"
    cat > "$STUB/fab-chroot" <<'STUBEOF'
#!/bin/bash
echo "fab-chroot $*" >> "$BATS_TEST_TMPDIR/calls"
[[ ${FAKE_FAB:-} == fail ]] && exit 1
[[ ${FAKE_DPKG:-ok} == ok ]] && rm -f "$1"/*.deb
exit 0
STUBEOF
    chmod +x "$STUB/fab-chroot"
    export PATH="$STUB:$PATH"
}

@test "no .deb: does not call fab-chroot and exits 0" {
    run "$SCRIPT" "$ROOTFS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to install"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "a .deb that dpkg installs: removed, exits 0" {
    : > "$ROOTFS/a_1_all.deb"
    : > "$ROOTFS/b_1_all.deb"
    FAKE_DPKG=ok run "$SCRIPT" "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/a_1_all.deb" ]
    grep -q 'dpkg -i /\*.deb' "$BATS_TEST_TMPDIR/calls"
}

@test "dpkg fails but fab-chroot exits 0: the .deb left in the root fails the build" {
    : > "$ROOTFS/a_1_all.deb"
    FAKE_DPKG=fail run "$SCRIPT" "$ROOTFS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"did not install: a_1_all.deb"* ]]
}

@test "fab-chroot itself fails: exits 1" {
    : > "$ROOTFS/a_1_all.deb"
    FAKE_FAB=fail run "$SCRIPT" "$ROOTFS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"fab-chroot failed"* ]]
}

@test "bad usage: no argument or not a directory exits 2" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    run "$SCRIPT" "$BATS_TEST_TMPDIR/missing"
    [ "$status" -eq 2 ]
}

@test "the two shared makefiles call install-debs, not dpkg -i *.deb" {
    for mk in turnkey.mk turnkey-desktop.mk; do
        grep -q 'mk/turnkey/install-debs \$O/root.patched' "$BATS_TEST_DIRNAME/../mk/$mk"
        run grep -c 'dpkg -i \*\.deb' "$BATS_TEST_DIRNAME/../mk/$mk"
        [ "$output" = 0 ]
    done
}
