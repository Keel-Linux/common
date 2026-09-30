#!/usr/bin/env bats
# The Core overlay packages of packages/, installed on a Debian 13 machine:
# each leaves its units in the state of a simple installation, and its
# manifest validates there (decision 0041, first implementation, step 2).
#
# This suite changes the machine it runs on: it removes, installs and
# reinstalls packages and enables and disables units. It runs only where
# KEEL_OVERLAY_INSTALL_TEST=1 says the machine is disposable, as root, after
# the four keel-overlay-* packages have been installed with their
# dependencies. OVERLAY_DEBS names the directory holding the four .deb files
# (default dist/ of the repository). The CI job "packages" runs it in a
# trixie container; the same suite runs on a booted container, where
# systemd is PID 1 and the is-active assertions are made as well.
#
# Every verdict is the one systemctl, dpkg, apt and keel give on the
# machine; nothing reads back a file the packages wrote to decide a state.
#
# Refutations are written "run ! cmd", never a bare "! cmd": bash does not
# apply errexit to a negated command, so a bare one asserts nothing unless
# it happens to be the last command of its test.

bats_require_minimum_version 1.5.0

OVERLAYS=(installer wireguard etcd crowdsec)
# the units the simple installation of Keel Core keeps disabled and stopped
DISABLED_UNITS=(etcd.service crowdsec.service crowdsec-firewall-bouncer.service)

setup_file() {
    if [ "${KEEL_OVERLAY_INSTALL_TEST:-}" != 1 ]; then
        echo "refusing to run: this suite installs and removes packages;" \
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
    REPO="$(cd "$TESTS_DIR/.." && pwd)"
    DEBS="${OVERLAY_DEBS:-$REPO/dist}"
    export DEBIAN_FRONTEND=noninteractive
}

teardown() {
    # a test that enabled a unit to play keel apply leaves it as it found it
    if [ -n "${ENABLED_BY_TEST:-}" ]; then
        systemctl disable $ENABLED_BY_TEST >/dev/null 2>&1 || true
        if systemd_running; then
            systemctl stop $ENABLED_BY_TEST >/dev/null 2>&1 || true
        fi
    fi
}

systemd_running() {
    [ -d /run/systemd/system ]
}

overlay_deb() {
    local debs=("$DEBS"/keel-overlay-"$1"_*_all.deb)
    [ -f "${debs[0]}" ] || {
        echo "no keel-overlay-$1 package in $DEBS" >&2
        return 1
    }
    echo "${debs[0]}"
}

assert_enabled_state() {
    local unit="$1" expected="$2"
    run systemctl is-enabled "$unit"
    echo "systemctl is-enabled $unit: $output"
    [ "$output" = "$expected" ]
}

assert_active_state() {
    local unit="$1" expected="$2"
    systemd_running || return 0
    run systemctl is-active "$unit"
    echo "systemctl is-active $unit: $output"
    [ "$output" = "$expected" ]
}

assert_simple_state() {
    local unit
    for unit in "${DISABLED_UNITS[@]}"; do
        assert_enabled_state "$unit" disabled
        assert_active_state "$unit" inactive
    done
}

# ------------------------------------------------------------ the packages

@test "the four overlay packages are installed" {
    local name
    for name in "${OVERLAYS[@]}"; do
        run dpkg-query -W -f='${db:Status-Status}' "keel-overlay-$name"
        [ "$status" -eq 0 ]
        [ "$output" = installed ]
    done
}

@test "each manifest is installed where docs/manifest-v1.md puts it, as its source says" {
    local name
    for name in "${OVERLAYS[@]}"; do
        cmp "$REPO/packages/$name/manifest.yaml" \
            "/usr/share/keel/overlays/$name.yaml"
    done
}

@test "each manifest is shipped by its own overlay package" {
    local name
    for name in "${OVERLAYS[@]}"; do
        run dpkg-query -S "/usr/share/keel/overlays/$name.yaml"
        [ "$status" -eq 0 ]
        [ "$output" = "keel-overlay-$name: /usr/share/keel/overlays/$name.yaml" ]
    done
}

# ------------------------------------------------------- keel on the machine

@test "keel manifest validate accepts each overlay on this machine" {
    local name
    for name in "${OVERLAYS[@]}"; do
        run keel manifest validate --kind overlay "$name"
        echo "keel manifest validate --kind overlay $name: $status $output"
        [ "$status" -eq 0 ]
    done
}

@test "keel manifest validate accepts every manifest installed on this machine" {
    run keel manifest validate
    echo "$output"
    [ "$status" -eq 0 ]
}

# ------------------------------------------------------ the simple state

@test "etcd and both CrowdSec units are disabled and inactive after installation" {
    assert_simple_state
}

@test "the preset systemd applies at first boot says disabled for each unit" {
    local unit
    for unit in "${DISABLED_UNITS[@]}"; do
        # the PRESET column is systemd's own reading of every preset file
        run systemctl list-unit-files --no-legend "$unit"
        echo "$output"
        [ "$status" -eq 0 ]
        [ "$(awk '{print $3}' <<<"$output")" = disabled ]
    done
}

@test "a first boot preset in enable-only mode leaves the units disabled" {
    # what PID 1 does on a first boot, when /etc/machine-id is missing or
    # says "uninitialized"
    systemctl preset --preset-mode=enable-only "${DISABLED_UNITS[@]}"
    assert_simple_state
}

@test "a first install disables and stops what the Debian packages enabled" {
    dpkg -r keel-overlay-etcd keel-overlay-crowdsec
    # the state Debian's own postinst leaves on a machine without the overlay
    systemctl enable "${DISABLED_UNITS[@]}"
    if systemd_running; then
        systemctl start etcd.service crowdsec.service
    fi
    assert_enabled_state crowdsec.service enabled

    dpkg -i "$(overlay_deb etcd)" "$(overlay_deb crowdsec)"

    assert_simple_state
}

@test "an upgrade of the Debian packages keeps the units disabled and stopped" {
    apt-get install -y -q --reinstall \
        etcd-server crowdsec crowdsec-firewall-bouncer
    assert_simple_state
}

@test "an upgrade of the overlay keeps a unit that keel apply enabled" {
    ENABLED_BY_TEST="crowdsec.service"
    systemctl enable crowdsec.service

    dpkg -i "$(overlay_deb crowdsec)"

    assert_enabled_state crowdsec.service enabled
}

@test "an upgrade of the Debian package keeps a unit that keel apply enabled" {
    ENABLED_BY_TEST="etcd.service"
    systemctl enable etcd.service

    apt-get install -y -q --reinstall etcd-server

    assert_enabled_state etcd.service enabled
}

@test "keel apply can still enable the units: none of them is masked" {
    local unit
    for unit in "${DISABLED_UNITS[@]}"; do
        run systemctl is-enabled "$unit"
        [ "$output" != masked ]
        [ ! -L "/etc/systemd/system/$unit" ]
    done
}
