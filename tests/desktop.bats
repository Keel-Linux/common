#!/usr/bin/env bats
# conf/desktop, run with every command it calls replaced by a stub first in
# PATH, so nothing on the host is touched. chmod behaves as the real one
# does on a file that is not there: it fails, and under bash -e the build
# stops.
#
# Keel-Linux/inithooks#29 removed firstboot.d/80hub-services (its Keel
# Cloud screen, 80keel-cloud, takes its place), and conf/desktop still ran
# chmod -x on it, so every desktop build would have failed.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    DESKTOP="$TESTS_DIR/../conf/desktop"
    STUBS="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUBS"
    for name in useradd cp chown sed; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' \
            "$name" "$BATS_TEST_TMPDIR" > "$STUBS/$name"
    done
    printf '#!/bin/sh\necho "chmod $*" >> "%s/calls"\n%s\n' \
        "$BATS_TEST_TMPDIR" '[ "$1" = 0700 ] || [ -e "$2" ] || exit 1' \
        > "$STUBS/chmod"
    /bin/chmod +x "$STUBS"/*
    PATH="$STUBS:$PATH"
}

@test "a desktop build does not stop on the TurnKey Hub hook inithooks no longer ships" {
    run "$DESKTOP"

    [ "$status" -eq 0 ]
    run ! grep -q hub-services "$BATS_TEST_TMPDIR/calls"
}

@test "the graphical user is still made" {
    run "$DESKTOP"

    [ "$status" -eq 0 ]
    grep -q "^useradd .*--uid=999 user$" "$BATS_TEST_TMPDIR/calls"
    grep -q "^chmod 0700 /home/user$" "$BATS_TEST_TMPDIR/calls"
}
