#!/usr/bin/env bats
# Tests for conf/turnkey.d/container-units: the units a Keel image boots
# with that cannot do their work in an unprivileged container, found failed
# on a Keel Web LXC container (systemctl --failed, 2026-10-03).
#
# systemctl is the stub of tests/stubs, which records its arguments in
# STUB_LOG. The drop-ins go to a scratch systemd tree, beside copies of the
# packaged units from tests/fixtures (systemd 257.13, ntpsec 1.2.3 of
# trixie), so that systemd reads each pair together: the verdict on the
# condition is systemd's own, from 'systemd-analyze condition', and the
# merged units are handed to 'systemd-analyze verify' so that systemd, and
# not a reader, says they parse.

bats_require_minimum_version 1.5.0

load helpers

UNITS=(ntpsec.service sys-kernel-config.mount sys-kernel-debug.mount)

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../conf/turnkey.d/container-units"
    scratch_image
}

dropin() {
    echo "$SYSTEMD_DIR/$1.d/keel-container.conf"
}

# packaged UNIT
# The unit as its package installs it, beside the drop-in the way it is in
# an image. Only ntpsec's program is swapped for one that exists here, which
# 'systemd-analyze verify' checks and nothing else depends on.
packaged() {
    sed 's|^ExecStart=/usr/libexec/ntpsec/ntp-systemd-wrapper|ExecStart=/bin/true|' \
        "$FIXTURES/$1" > "$SYSTEMD_DIR/$1"
    echo "$SYSTEMD_DIR/$1"
}

@test "disables networkd, its socket and wait-online, and calls systemctl for nothing else" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_LOG")" = "systemctl disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service" ]
}

@test "writes a keel-container drop-in for ntpsec and both kernel mounts, and nothing else" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    local unit
    for unit in "${UNITS[@]}"; do
        [ "$(cat "$(dropin "$unit")")" = "$(printf '[Unit]\nConditionVirtualization=!container')" ]
    done
    [ "$(find "$SYSTEMD_DIR" -type f | wc -l)" -eq "${#UNITS[@]}" ]
}

@test "the condition is the one systemd knows, and it holds here unless this is a container" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    local unit
    for unit in "${UNITS[@]}"; do
        if systemd-detect-virt --container >/dev/null; then
            run ! unit_would_start "$(dropin "$unit")"
        else
            run unit_would_start "$(dropin "$unit")"
            [ "$status" -eq 0 ]
        fi
    done
}

@test "systemd accepts each packaged unit with its drop-in in place" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    local unit
    for unit in "${UNITS[@]}"; do
        run systemd-analyze verify --man=no "$(packaged "$unit")"
        echo "systemd-analyze verify $unit: $output"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "the drop-in is read beside the packaged capability condition, which stays" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    local unit
    for unit in "${UNITS[@]}"; do
        packaged "$unit" >/dev/null
        grep -q '^ConditionCapability=' "$SYSTEMD_DIR/$unit"
        run conditions_of "$SYSTEMD_DIR/$unit" "$(dropin "$unit")"
        [ "$status" -eq 0 ]
        [[ "$output" == *ConditionCapability=*ConditionVirtualization=!container ]]
    done
}
