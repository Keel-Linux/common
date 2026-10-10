#!/usr/bin/env bats
# Tests for conf/turnkey.d/container-units: the units a Keel image boots
# with that cannot do their work in an unprivileged container, found failed
# on a Keel Web LXC container (systemctl --failed, 2026-10-03).
#
# systemctl is the stub of tests/stubs, which records its arguments in
# STUB_LOG. The drop-ins go to a scratch systemd tree, beside copies of the
# packaged units from tests/fixtures (systemd 257.13, ntpsec 1.2.3 of
# trixie; systemd-modules-load.service of systemd 257.13), so that systemd reads each pair together: the verdict on the
# condition is systemd's own, from 'systemd-analyze condition', and the
# merged units are handed to 'systemd-analyze verify' so that systemd, and
# not a reader, says they parse. For networkd the three packaged units and
# trixie's 90-systemd.preset (systemd 257.13) go under the scratch tree's
# usr/lib, and the real systemctl, offline with --root, applies the presets
# of a first boot to it and tries an enable.

bats_require_minimum_version 1.5.0

load helpers

UNITS=(ntpsec.service sys-kernel-config.mount sys-kernel-debug.mount systemd-modules-load.service)
NETWORKD=(systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service)

# The systemctl of the system, not the stub: the preset tests ask systemd
# itself, offline, what it makes of the scratch tree.
SYSTEMCTL=/usr/bin/systemctl

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

# packaged_networkd
# The scratch image as a build leaves it for its first boot: the three
# networkd units and trixie's 90-systemd.preset, which says enable for the
# service and wait-online and reaches the socket through the service's
# Also=, under usr/lib, with the script's links in etc/systemd/system.
packaged_networkd() {
    mkdir -p "$IMAGE/usr/lib/systemd/system" "$IMAGE/usr/lib/systemd/system-preset"
    local unit
    for unit in "${NETWORKD[@]}"; do
        cp "$FIXTURES/$unit" "$IMAGE/usr/lib/systemd/system/$unit"
    done
    cp "$FIXTURES/90-systemd.preset" "$IMAGE/usr/lib/systemd/system-preset/"
}

@test "masks networkd, its socket and wait-online: each is a link to /dev/null" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    local unit
    for unit in "${NETWORKD[@]}"; do
        [ -L "$SYSTEMD_DIR/$unit" ]
        [ "$(readlink "$SYSTEMD_DIR/$unit")" = /dev/null ]
    done
}

@test "a first boot preset, in either mode, leaves all three masked and none enabled" {
    packaged_networkd
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    local mode unit
    for mode in enable-only full; do
        # masked units make preset-all report a failure; the state is the verdict
        "$SYSTEMCTL" --root="$IMAGE" preset-all --preset-mode="$mode" >/dev/null 2>&1 || true
        for unit in "${NETWORKD[@]}"; do
            run "$SYSTEMCTL" --root="$IMAGE" is-enabled "$unit"
            echo "after preset-all $mode, $unit: $output"
            [ "$output" = masked ]
        done
        run find "$SYSTEMD_DIR" -path '*.wants/*' -name 'systemd-networkd*'
        [ -z "$output" ]
    done
}

@test "an enable, as a package's maintainer script would run it, is refused" {
    packaged_networkd
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run "$SYSTEMCTL" --root="$IMAGE" enable systemd-networkd.service
    [ "$status" -ne 0 ]
    [[ "$output" == *masked* ]]
    run find "$SYSTEMD_DIR" -path '*.wants/*' -name 'systemd-networkd*'
    [ -z "$output" ]
}

@test "the script runs again on a tree it has masked, and the result is the same" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    local unit
    for unit in "${NETWORKD[@]}"; do
        [ "$(readlink "$SYSTEMD_DIR/$unit")" = /dev/null ]
    done
}

@test "writes a keel-container drop-in for ntpsec, both kernel mounts and systemd-modules-load, and nothing else" {
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

@test "systemd-modules-load gets the drop-in, beside its packaged conditions" {
    # A container has no kernel and no /lib/modules (handbook decision 0052),
    # but kmod ships /etc/modules-load.d/modules.conf, which satisfies a
    # triggering condition of the packaged unit, and CAP_SYS_MODULE passes in
    # the container's user namespace. Without the drop-in the unit runs and
    # fails: "Failed to initialize libkmod context: Operation not supported".
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    local unit=systemd-modules-load.service
    [ -f "$(dropin "$unit")" ]
    packaged "$unit" >/dev/null
    grep -q '^ConditionCapability=CAP_SYS_MODULE$' "$SYSTEMD_DIR/$unit"
    grep -q '^ConditionDirectoryNotEmpty=|/etc/modules-load.d$' "$SYSTEMD_DIR/$unit"
    run conditions_of "$SYSTEMD_DIR/$unit" "$(dropin "$unit")"
    [[ "$output" == *ConditionVirtualization=!container ]]
}

@test "the drop-in names a container only, so a VM or the ISO boot layer still loads modules" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    local dropin_file
    dropin_file="$(dropin systemd-modules-load.service)"
    # the one condition, nothing else that would stop a VM or a bare install
    [ "$(grep -c '^Condition' "$dropin_file")" -eq 1 ]
    run systemd-analyze condition 'ConditionVirtualization=!container'
    if systemd-detect-virt --container >/dev/null; then
        [ "$status" -ne 0 ]
    else
        [ "$status" -eq 0 ]
    fi
    # nothing in the boot layer masks it or removes the drop-in
    run grep -rn 'modules-load' "$TESTS_DIR/../conf/keel-boot" "$TESTS_DIR/../plans/keel-boot"
    [ "$status" -ne 0 ]
}
