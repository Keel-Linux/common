#!/usr/bin/env bats
# The Syncthing overlay of packages/, installed on a Debian 13 machine:
# the manifest validates there, the service is in the state of a simple
# installation, and the unit hardening is the one of the decision 0050
# amendment (item 6).
#
# This suite starts and stops syncthing.service and changes nothing else.
# It runs only where KEEL_OVERLAY_INSTALL_TEST=1 says the machine is
# disposable, as root, with keel-overlay-syncthing and its dependencies
# installed (keel, the syncthing binary package and keel-overlay-wireguard).
# The CI job "syncthing" of .forgejo/workflows/packages.yml runs it in a
# booted trixie LXC container.
#
# That the ambient capabilities keep the application's owner on a received
# file is the proof on unprivileged LXC containers of the pull request, not
# of this suite: here the verdicts are the ones systemctl, dpkg and the
# health helper give on the machine.

bats_require_minimum_version 1.5.0

setup_file() {
    if [ "${KEEL_OVERLAY_INSTALL_TEST:-}" != 1 ]; then
        echo "refusing to run: this suite starts and stops syncthing.service;" \
            "set KEEL_OVERLAY_INSTALL_TEST=1 on a disposable machine" >&2
        return 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo "refusing to run: needs root" >&2
        return 1
    fi
}

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
}

teardown_file() {
    systemctl stop syncthing.service 2>/dev/null || true
}

# ------------------------------------------------------------- the manifest

@test "keel manifest validate accepts the syncthing overlay on this machine" {
    run keel manifest validate --kind overlay syncthing
    echo "keel manifest validate --kind overlay syncthing: $status $output"
    [ "$status" -eq 0 ]
}

@test "keel manifest validate accepts every manifest installed on this machine" {
    run keel manifest validate
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "the installed manifest is the one the package ships" {
    cmp "$TESTS_DIR/../packages/syncthing/manifest.yaml" \
        /usr/share/keel/overlays/syncthing.yaml
    run dpkg-query -S /usr/share/keel/overlays/syncthing.yaml
    [ "$output" = "keel-overlay-syncthing: /usr/share/keel/overlays/syncthing.yaml" ]
}

# ------------------------------------------------- the state of a simple installation

@test "syncthing.service is disabled and inactive after installation" {
    run systemctl is-enabled syncthing.service
    [ "$output" = disabled ]
    run systemctl is-active syncthing.service
    [ "$output" = inactive ]
}

@test "the preset says disable, so a first boot preset leaves the service off" {
    grep -qx "disable syncthing.service" \
        /usr/lib/systemd/system-preset/20-keel-overlay-syncthing.preset
}

@test "the service is not masked" {
    run systemctl is-enabled syncthing.service
    [ "$output" != masked ]
}

# ------------------------------------------------------------------ the user

@test "the syncthing user exists, a system user with its home" {
    run getent passwd syncthing
    [ "$status" -eq 0 ]
    local user home shell
    user=$(cut -d: -f1 <<< "$output")
    home=$(cut -d: -f6 <<< "$output")
    shell=$(cut -d: -f7 <<< "$output")
    [ "$user" = syncthing ]
    [ "$home" = /var/lib/syncthing ]
    [ "$shell" = /usr/sbin/nologin ]
    run getent group syncthing
    [ "$status" -eq 0 ]
}

@test "the home belongs to the user" {
    local owner
    owner=$(stat -c %U:%G /var/lib/syncthing)
    [ "$owner" = syncthing:syncthing ]
}

# ----------------------------------------------------------------- the unit

@test "the unit has the capabilities and the sandbox of the amendment" {
    local unit=/usr/lib/systemd/system/syncthing.service
    grep -qx "AmbientCapabilities=CAP_CHOWN CAP_FOWNER CAP_DAC_OVERRIDE" "$unit"
    grep -qx "ProtectSystem=strict" "$unit"
    grep -qx "ReadWritePaths=/var/lib/syncthing" "$unit"
    grep -qx "User=syncthing" "$unit"
}

@test "the unit names no configuration: keel renders it" {
    run ! grep -q "ExecStart=.*--config\|EnvironmentFile" \
        /usr/lib/systemd/system/syncthing.service
}

# ------------------------------------------------------- a run of the service

@test "the service runs as the syncthing user and answers the health check" {
    systemctl start syncthing.service

    # the first start generates the key and the configuration in the home
    local tries=0
    while [ ! -s /var/lib/syncthing/config.xml ] && [ "$tries" -lt 50 ]; do
        sleep 0.2
        tries=$((tries + 1))
    done
    [ -s /var/lib/syncthing/config.xml ]

    run systemctl is-active syncthing.service
    [ "$output" = active ]

    local pid user
    pid=$(systemctl show -p MainPID --value syncthing.service)
    [ "$pid" -gt 0 ]
    user=$(ps -o user= -p "$pid")
    [ "$user" = syncthing ]

    # the generated configuration names an API key; the health helper
    # reads it and asks the REST API on the loopback
    run /usr/lib/keel-overlay-syncthing/health
    echo "$output"
    [ "$status" -eq 0 ]

    # the GUI answers on the IPv4 loopback only
    run ss -ltn
    [[ "$output" == *"127.0.0.1:8384"* ]]
    [[ "$output" != *"[::]:8384"* ]]

    systemctl stop syncthing.service
    run systemctl is-active syncthing.service
    [ "$output" = inactive ]
}
