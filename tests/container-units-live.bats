#!/usr/bin/env bats
# conf/turnkey.d/container-units applied to a booted unprivileged container:
# systemd skips ntpsec and the two kernel mounts on their condition, and
# starting them adds nothing to 'systemctl --failed', where the packaged
# units alone fail (the mounts) or run and fail every clock adjustment
# (ntpd). The CI container has failures of its own at boot (its runner's
# AppArmor profile lets it mount nothing), so the suite does not ask for an
# empty list, only for no unit of this change in it and no new one.
#
# This suite changes the machine it runs on: it disables networkd, writes
# drop-ins under /etc/systemd/system and starts units. It runs only where
# KEEL_OVERLAY_INSTALL_TEST=1 says the machine is disposable, as root, in a
# container with systemd as PID 1, with ntpsec installed. The CI job
# "install" of packages.yml runs it last, in its trixie LXC container, after
# tests/overlay-install.bats. setup_file applies the script to the machine,
# as a build does to an image, and the tests read the machine back; every
# verdict is systemctl's, nothing reads a file the script wrote to decide a
# state. teardown_file takes the drop-ins away and re-enables what was
# enabled before.

bats_require_minimum_version 1.5.0

UNITS=(ntpsec.service sys-kernel-config.mount sys-kernel-debug.mount)
NETWORKD=(systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service)

setup_file() {
    if [ "${KEEL_OVERLAY_INSTALL_TEST:-}" != 1 ]; then
        echo "refusing to run: this suite disables units and writes drop-ins;" \
            "set KEEL_OVERLAY_INSTALL_TEST=1 on a disposable machine" >&2
        return 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo "refusing to run: needs root" >&2
        return 1
    fi
    if [ ! -d /run/systemd/system ]; then
        echo "refusing to run: systemd is not running here" >&2
        return 1
    fi
    if ! systemd-detect-virt --container >/dev/null; then
        echo "refusing to run: not a container, the conditions would hold" >&2
        return 1
    fi
    # what the script disables, to put back afterwards
    WAS_ENABLED="$(systemctl is-enabled "${NETWORKD[@]}" 2>/dev/null \
        | paste -d' ' - - - || true)"
    export WAS_ENABLED
    # what had failed by the time the suite started: the runner's own, not
    # the image's (keel-lxc-1's AppArmor profile lets the container mount
    # nothing, so its dev-mqueue, run-lock and tmp mounts fail at boot)
    FAILED_AT_START="$(systemctl --failed --no-legend --plain | awk '{ print $1 }')"
    export FAILED_AT_START
    # bats runs teardown_file after a setup_file that refused; only a
    # setup_file that got this far has anything to put back
    export LIVE_ARMED=1

    # the script, as a build runs it, on this machine
    "$(dirname "$BATS_TEST_FILENAME")/../conf/turnkey.d/container-units"
    systemctl daemon-reload
}

teardown_file() {
    [ "${LIVE_ARMED:-}" = 1 ] || return 0
    local unit i
    for unit in "${UNITS[@]}"; do
        rm -rf "/etc/systemd/system/$unit.d"
    done
    i=0
    for unit in "${NETWORKD[@]}"; do
        i=$((i + 1))
        if [ "$(echo "$WAS_ENABLED" | cut -d' ' -f"$i")" = enabled ]; then
            systemctl enable "$unit" >/dev/null 2>&1 || true
        fi
    done
    systemctl daemon-reload
}

@test "ntpsec is installed, the time daemon the base plan installs" {
    run dpkg-query -W -f='${db:Status-Status}' ntpsec
    [ "$output" = installed ]
}

@test "networkd, its socket and wait-online are disabled" {
    local unit
    for unit in "${NETWORKD[@]}"; do
        run systemctl is-enabled "$unit"
        echo "systemctl is-enabled $unit: $output"
        [ "$output" = disabled ]
    done
}

@test "systemd loads the drop-in, reads its condition as unmet here, and skips each unit" {
    local unit where expected
    for unit in "${UNITS[@]}"; do
        run systemctl show -p DropInPaths --value "$unit"
        echo "DropInPaths of $unit: $output"
        [[ "$output" == *"/etc/systemd/system/$unit.d/keel-container.conf"* ]]
    done
    for unit in "${UNITS[@]}"; do
        systemctl reset-failed "$unit"
        run systemctl start "$unit"
        echo "systemctl start $unit: $output"
        [ "$status" -eq 0 ]
        # a mount the runtime made before systemd is active without a start,
        # so the condition is never asked; the others are skipped on it
        where="$(systemctl show -p Where --value "$unit")"
        if [ -n "$where" ] && mountpoint -q "$where"; then
            echo "$where is a mount point already"
            expected=active
        else
            run systemctl show -p ConditionResult --value "$unit"
            [ "$output" = no ]
            expected=inactive
        fi
        run systemctl is-active "$unit"
        echo "systemctl is-active $unit: $output"
        [ "$output" = "$expected" ]
    done
}

@test "starting the units under the drop-ins adds nothing to systemctl --failed" {
    echo "failed at the start of the suite: ${FAILED_AT_START:-nothing}"
    systemctl reset-failed
    systemctl start "${UNITS[@]}"
    run systemctl --failed --no-legend --plain
    echo "failed after the start: ${output:-nothing}"
    [ "$status" -eq 0 ]
    local unit
    for unit in $(echo "$output" | awk '{ print $1 }'); do
        # a unit of this machine that failed before the suite may fail
        # again; one of ours, or a new one, is a failure of the change
        [[ " ${UNITS[*]} ${NETWORKD[*]} " != *" $unit "* ]]
        [[ " ${FAILED_AT_START//$'\n'/ } " == *" $unit "* ]]
    done
}

@test "none of them is masked: a console can still ask for them" {
    local unit
    for unit in "${UNITS[@]}"; do
        run systemctl is-enabled "$unit"
        echo "systemctl is-enabled $unit: $output"
        [ "$output" != masked ]
    done
}
