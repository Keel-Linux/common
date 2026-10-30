#!/usr/bin/env bats
# The insserv step of mk/turnkey-desktop.mk (fab#15). fab chroot now exits
# with the status of a command string, so the step must exit 0 when insserv
# is not installed, and fail when insserv is installed and fails.

setup() {
    step="$(sed -n 's|^\tfab-chroot \$O/root.patched "\(.*insserv.*\)"$|\1|p' \
        "$BATS_TEST_DIRNAME/../mk/turnkey-desktop.mk")"
    bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    path="$bin:/usr/bin:/bin"
    if PATH="$path" command -v insserv >/dev/null; then
        skip "insserv is installed on this host outside $bin"
    fi
}

run_step() {
    run env PATH="$path" /bin/bash -c "$step"
}

@test "the makefile has one insserv step" {
    [ -n "$step" ]
    [[ "$step" != *$'\n'* ]]
}

@test "with no insserv the step exits 0" {
    run_step
    [ "$status" -eq 0 ]
}

@test "an insserv that fails makes the step fail" {
    printf '#!/bin/sh\nexit 3\n' > "$bin/insserv"
    chmod 755 "$bin/insserv"
    run_step
    [ "$status" -eq 3 ]
}

@test "an insserv that works makes the step exit 0" {
    printf '#!/bin/sh\nexit 0\n' > "$bin/insserv"
    chmod 755 "$bin/insserv"
    run_step
    [ "$status" -eq 0 ]
}
