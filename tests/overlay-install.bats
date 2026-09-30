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

# with_version DEB VERSION
# A copy of DEB rebuilt with dpkg-deb under VERSION, everything else as it
# is, maintainer scripts included: installing it over DEB is a real upgrade,
# "configure" with the previous version, not a reinstall of the same one.
with_version() {
    local deb="$1" version="$2" tree
    tree="$(mktemp -d "$BATS_TEST_TMPDIR/deb.XXXXXX")"
    dpkg-deb -R "$deb" "$tree/root"
    awk -v v="$version" '/^Version: / { $0 = "Version: " v } { print }' \
        "$tree/root/DEBIAN/control" > "$tree/control"
    mv "$tree/control" "$tree/root/DEBIAN/control"
    dpkg-deb -b "$tree/root" "$tree/$(basename "$deb" .deb)-$version.deb" >&2
    echo "$tree/$(basename "$deb" .deb)-$version.deb"
}

# debian_upgrade SUFFIX PACKAGE...
# Upgrades each Debian PACKAGE to its archive version plus SUFFIX
debian_upgrade() {
    local suffix="$1" package archived deb debs=()
    shift
    for package in "$@"; do
        # the archive's version: apt-get download alone asks for the
        # installed one, which after an earlier upgrade is no archive's
        archived="$(apt-cache madison "$package" | awk 'NR == 1 { print $3 }')"
        (cd "$BATS_TEST_TMPDIR" && apt-get download -q "$package=$archived")
        deb="$(ls "$BATS_TEST_TMPDIR/${package}"_*.deb)"
        debs+=("$(with_version "$deb" "$(dpkg-deb -f "$deb" Version)$suffix")")
    done
    dpkg -i "${debs[@]}"
    for package in "$@"; do
        run dpkg-query -W -f='${Version}' "$package"
        [[ "$output" == *"$suffix" ]]
    done
}

enable_unit() {
    ENABLED_BY_TEST="${ENABLED_BY_TEST:+$ENABLED_BY_TEST }$*"
    systemctl enable "$@"
    if systemd_running; then
        systemctl start "$@"
    fi
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

@test "a first install disables and stops what the Debian packages enabled with it" {
    # purged, so nothing of either overlay is left and the next
    # configuration is a first one; the Debian packages go too, so that
    # their postinst enables and starts the units in the same transaction
    dpkg -P keel-overlay-etcd keel-overlay-crowdsec
    run dpkg-query -W -f='${db:Status-Status}' keel-overlay-etcd
    [ "$output" != config-files ]
    apt-get purge -y -q etcd-server crowdsec crowdsec-firewall-bouncer
    rm -rf /etc/crowdsec /var/lib/crowdsec /var/lib/etcd

    apt-get install -y -q --no-install-recommends \
        "$(overlay_deb etcd)" "$(overlay_deb crowdsec)"

    assert_simple_state
}

@test "a first install leaves a unit that was enabled and running before it" {
    # the transition of a machine that ran CrowdSec before the overlay
    dpkg -P keel-overlay-crowdsec
    enable_unit crowdsec.service
    assert_enabled_state crowdsec-firewall-bouncer.service disabled

    dpkg -i "$(overlay_deb crowdsec)"

    assert_enabled_state crowdsec.service enabled
    assert_active_state crowdsec.service active
    # what nobody had turned on is still put in the simple state
    assert_enabled_state crowdsec-firewall-bouncer.service disabled
    assert_active_state crowdsec-firewall-bouncer.service inactive
}

@test "remove, then reinstall, keeps an enabled etcd enabled and active" {
    enable_unit etcd.service

    dpkg -r keel-overlay-etcd
    # postrm is what keeps the package known to dpkg after a remove, so the
    # reinstall is configured as an upgrade from the version removed
    run dpkg-query -W -f='${db:Status-Status}' keel-overlay-etcd
    [ "$output" = config-files ]
    dpkg -i "$(overlay_deb etcd)"

    assert_enabled_state etcd.service enabled
    assert_active_state etcd.service active
}

@test "an upgrade of the Debian packages keeps the units disabled and stopped" {
    debian_upgrade +keeltest1 etcd-server crowdsec crowdsec-firewall-bouncer
    assert_simple_state
}

@test "an upgrade of the Debian package keeps a unit that keel apply enabled" {
    enable_unit etcd.service

    debian_upgrade +keeltest2 etcd-server

    assert_enabled_state etcd.service enabled
    assert_active_state etcd.service active
}

@test "an upgrade of the overlay keeps a unit that keel apply enabled" {
    enable_unit crowdsec.service

    dpkg -i "$(with_version "$(overlay_deb crowdsec)" 0.1.1)"

    run dpkg-query -W -f='${Version}' keel-overlay-crowdsec
    [ "$output" = 0.1.1 ]
    assert_enabled_state crowdsec.service enabled
    assert_active_state crowdsec.service active
    assert_enabled_state crowdsec-firewall-bouncer.service disabled
}

@test "keel apply can still enable the units: none of them is masked" {
    local unit
    for unit in "${DISABLED_UNITS[@]}"; do
        run systemctl is-enabled "$unit"
        [ "$output" != masked ]
        [ ! -L "/etc/systemd/system/$unit" ]
    done
}
