#!/usr/bin/env bats
# The Core overlay packages of packages/, installed on a Debian 13 machine:
# each leaves its units in the state of a simple installation, and its
# manifest validates there (decision 0041, first implementation, step 2).
#
# This suite changes the machine it runs on: it removes, installs and
# reinstalls packages and enables and disables units. It runs only where
# KEEL_OVERLAY_INSTALL_TEST=1 says the machine is disposable, as root, after
# the five keel-overlay-* packages have been installed with their
# dependencies. OVERLAY_DEBS names the directory holding the five .deb files
# (default dist/ of the repository). The CI job "install" runs it in a
# booted trixie LXC container, where systemd is PID 1 and the is-active
# assertions are made as well; in a machine where systemd does not run
# those are skipped.
#
# Every verdict is the one systemctl, dpkg, apt and keel give on the
# machine; nothing reads back a file the packages wrote to decide a state.
#
# Refutations are written "run ! cmd", never a bare "! cmd": bash does not
# apply errexit to a negated command, so a bare one asserts nothing unless
# it happens to be the last command of its test.

bats_require_minimum_version 1.5.0

OVERLAYS=(installer wireguard etcd crowdsec vip)
# the units the simple installation of Keel Core keeps disabled and stopped
DISABLED_UNITS=(etcd.service crowdsec.service crowdsec-firewall-bouncer.service keel-vip.service)

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
    # a test that died while it played an image build gives systemd back
    # its marker before anything else asks whether systemd runs
    restore_systemd_marker
    # a test that let the maintainer scripts act on units puts fab's
    # policy-rc.d back, and stops the VIP controller's stand-in
    restore_policy
    if [ -e "$VIP_STAND_IN" ]; then
        systemctl stop keel-vip.service >/dev/null 2>&1 || true
        rm -rf "${VIP_STAND_IN%/*}"
        systemctl daemon-reload
    fi
    # a test that enabled a unit to play keel apply leaves it as it found it
    if [ -n "${ENABLED_BY_TEST:-}" ]; then
        systemctl disable $ENABLED_BY_TEST >/dev/null 2>&1 || true
        if systemd_running; then
            systemctl stop $ENABLED_BY_TEST >/dev/null 2>&1 || true
        fi
    fi
    # a test that took the CrowdSec overlay away, or left the package that
    # conflicts with it, puts the machine back for the next one
    if dpkg-query -W keel-test-conflict >/dev/null 2>&1; then
        dpkg -P keel-test-conflict
    fi
    if [ "$(dpkg-query -W -f='${db:Status-Status}' keel-overlay-crowdsec \
            2>/dev/null)" != installed ]; then
        dpkg -i "$(overlay_deb crowdsec)"
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

# as_image_build COMMAND...
# Runs COMMAND as an image build sees the machine: no /run/systemd/system,
# the directory the maintainer scripts and systemctl test to know whether
# systemd is running. Where systemd runs, the directory is moved aside for
# the length of COMMAND and put back after it; where it is not there to
# begin with, COMMAND runs as it is. It is moved rather than hidden under a
# mount because an unprivileged LXC container, where CI runs this suite,
# may not mount anything: its AppArmor profile refuses the mount with
# EACCES. teardown puts it back if a test dies in between.
IMAGE_BUILD_HIDDEN=/run/systemd/system.keel-image-build

as_image_build() {
    local rc=0
    if ! systemd_running; then
        "$@"
        return
    fi
    mv /run/systemd/system "$IMAGE_BUILD_HIDDEN"
    "$@" || rc=$?
    mv "$IMAGE_BUILD_HIDDEN" /run/systemd/system
    return "$rc"
}

restore_systemd_marker() {
    if [ -d "$IMAGE_BUILD_HIDDEN" ] && [ ! -e /run/systemd/system ]; then
        mv "$IMAGE_BUILD_HIDDEN" /run/systemd/system
    fi
}

# a package owning the overlay manifest's path, so that unpacking the
# overlay fails after its preinst ran and dpkg calls postrm abort-install
conflicting_deb() {
    local tree="$BATS_TEST_TMPDIR/conflict"
    mkdir -p "$tree/DEBIAN" "$tree/usr/share/keel/overlays"
    printf '%s\n' "Package: keel-test-conflict" "Version: 1" \
        "Architecture: all" "Maintainer: Keel tests <admin@keellinux.org>" \
        "Description: owns crowdsec.yaml, for a test" > "$tree/DEBIAN/control"
    : > "$tree/usr/share/keel/overlays/crowdsec.yaml"
    dpkg-deb -b "$tree" "$BATS_TEST_TMPDIR/keel-test-conflict.deb" >&2
    echo "$BATS_TEST_TMPDIR/keel-test-conflict.deb"
}

KEPT_CROWDSEC=/var/lib/keel-overlay-crowdsec/kept-units

assert_enabled_state() {
    local unit="$1" expected="$2"
    run systemctl is-enabled "$unit"
    echo "systemctl is-enabled $unit: $output"
    [ "$output" = "$expected" ]
}

# fab's policy-rc.d, which the CI job writes and which refuses every
# action of deb-systemd-invoke, moved aside for a test that needs the
# maintainer scripts to act on units as on a running machine; teardown
# puts it back
POLICY=/usr/sbin/policy-rc.d
POLICY_HIDDEN=/usr/sbin/policy-rc.d.keel-test

allow_unit_actions() {
    if [ -e "$POLICY" ]; then
        mv "$POLICY" "$POLICY_HIDDEN"
    fi
}

restore_policy() {
    if [ -e "$POLICY_HIDDEN" ]; then
        mv "$POLICY_HIDDEN" "$POLICY"
    fi
}

# keel-vip.service with its ExecStart replaced by a sleep, and its
# condition on etcd's cluster lifted: what the maintainer scripts do to
# the unit is under test here, not the VIP, which keel's CI measures end
# to end (keel's tests/test_vip_upgrade_netns.py). A runtime drop-in,
# which teardown removes.
VIP_STAND_IN=/run/systemd/system/keel-vip.service.d/keel-test.conf

vip_stand_in() {
    mkdir -p "${VIP_STAND_IN%/*}"
    printf '%s\n' "[Unit]" "ConditionPathExists=" "[Service]" \
        "ExecStart=" "ExecStart=/bin/sleep infinity" "ExecStopPost=" \
        > "$VIP_STAND_IN"
    systemctl daemon-reload
}

invocation() {
    systemctl show --property=InvocationID --value "$1"
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

@test "the five overlay packages are installed" {
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

@test "the lone member etcd-server's own start made is marked for keel" {
    # etcd-server's postinst started etcd in the same transaction; the
    # overlay marks that member, which keel removes before it joins this
    # node to the mesh's cluster, and leaves etcd stopped
    if [ -d /var/lib/etcd/default/member ]; then
        [ -f /var/lib/keel-overlay-etcd/package-member ]
    fi
    run systemctl is-active etcd.service
    [ "$output" != active ]
}

@test "the VIP check timer is not enabled and not running: it belongs to the controller" {
    run systemctl is-enabled keel-vip-check.timer
    echo "$output"
    # no [Install]: systemd reports static, never enabled
    [ "$output" = static ]
    if systemd_running; then
        run systemctl is-active keel-vip-check.timer
        [ "$output" = inactive ]
    fi
    # the effective unit files as systemctl reads them: the timer is part of
    # the controller, and the controller wants it
    run systemctl cat keel-vip-check.timer
    [ "$status" -eq 0 ]
    grep -qx 'PartOf=keel-vip.service' <<<"$output"
    run ! grep -q '^\[Install\]' <<<"$output"
    run systemctl cat keel-vip.service
    [ "$status" -eq 0 ]
    grep -qE '^Wants=.*\bkeel-vip-check\.timer\b' <<<"$output"
}

@test "the VIP preset disables the controller and its check" {
    grep -qx 'disable keel-vip.service' /usr/lib/systemd/system-preset/20-keel-overlay-vip.preset
    grep -qx 'disable keel-vip-check.timer' /usr/lib/systemd/system-preset/20-keel-overlay-vip.preset
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
    # the transition of a machine that ran CrowdSec before the overlay; a
    # live system's only, the next test is the image build's
    systemd_running || skip "systemd is not running here: an image build"
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

@test "in an image build a first install disables units enabled beforehand" {
    # CrowdSec installed and enabled by one apt run of the build, the
    # overlay by a later one: without systemd running nothing is kept
    dpkg -P keel-overlay-crowdsec
    enable_unit crowdsec.service crowdsec-firewall-bouncer.service

    as_image_build dpkg -i "$(overlay_deb crowdsec)"

    assert_enabled_state crowdsec.service disabled
    assert_enabled_state crowdsec-firewall-bouncer.service disabled
    [ ! -e "$KEPT_CROWDSEC" ]
}

@test "a purge after an unpack that was never configured deletes kept-units" {
    dpkg -P keel-overlay-crowdsec
    dpkg --unpack "$(overlay_deb crowdsec)"
    [ -f "$KEPT_CROWDSEC" ]

    dpkg -P keel-overlay-crowdsec

    [ ! -e "$KEPT_CROWDSEC" ]
    [ ! -e "${KEPT_CROWDSEC%/*}" ]
}

@test "an unpack that fails after preinst deletes kept-units (abort-install)" {
    dpkg -P keel-overlay-crowdsec
    dpkg -i "$(conflicting_deb)"

    run dpkg --unpack "$(overlay_deb crowdsec)"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"trying to overwrite"* ]]
    [ ! -e "$KEPT_CROWDSEC" ]
}

@test "a configuration that failed and is retried still keeps what preinst recorded" {
    dpkg -P keel-overlay-crowdsec
    enable_unit crowdsec.service
    dpkg --unpack "$(overlay_deb crowdsec)"
    # the first configuration fails where it disables its first unit
    mkdir -p "$BATS_TEST_TMPDIR/fail"
    printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/fail/deb-systemd-helper"
    chmod 755 "$BATS_TEST_TMPDIR/fail/deb-systemd-helper"
    run env PATH="$BATS_TEST_TMPDIR/fail:$PATH" \
        dpkg --configure keel-overlay-crowdsec
    [ "$status" -ne 0 ]
    [ -f "$KEPT_CROWDSEC" ]

    dpkg --configure keel-overlay-crowdsec

    run dpkg-query -W -f='${db:Status-Status}' keel-overlay-crowdsec
    [ "$output" = installed ]
    [ ! -e "$KEPT_CROWDSEC" ]
    assert_enabled_state crowdsec-firewall-bouncer.service disabled
    if systemd_running; then
        # a live system: what ran before is kept across the retry
        assert_enabled_state crowdsec.service enabled
        assert_active_state crowdsec.service active
    else
        assert_enabled_state crowdsec.service disabled
    fi
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

@test "an upgrade of keel-overlay-vip restarts a running controller, never stops it for good" {
    systemd_running || skip "systemd does not run here"
    vip_stand_in
    allow_unit_actions
    systemctl start keel-vip.service
    local before
    before="$(invocation keel-vip.service)"

    dpkg -i "$(with_version "$(overlay_deb vip)" 0.2.0+keeltest1)"

    # 0.1.1's preinst stopped it and nothing started it again: the holder
    # dropped the VIP until a reboot. Now it is try-restarted: running,
    # as a new invocation, its check's timer with it
    assert_active_state keel-vip.service active
    [ "$(invocation keel-vip.service)" != "$before" ]
    assert_active_state keel-vip-check.timer active
    # and back to the built package, a configuration over a newer version
    dpkg -i "$(overlay_deb vip)"
    assert_active_state keel-vip.service active
}

@test "an upgrade of keel-overlay-vip starts no controller that was stopped" {
    systemd_running || skip "systemd does not run here"
    vip_stand_in
    allow_unit_actions
    systemctl stop keel-vip.service

    dpkg -i "$(with_version "$(overlay_deb vip)" 0.2.0+keeltest2)"

    assert_active_state keel-vip.service inactive
    assert_active_state keel-vip-check.timer inactive
    assert_enabled_state keel-vip.service disabled
    dpkg -i "$(overlay_deb vip)"
}

@test "an upgrade of keel restarts the VIP controller, so it runs the new code" {
    systemd_running || skip "systemd does not run here"
    [ -n "${KEEL_DEB:-}" ] || skip "KEEL_DEB names no keel package to upgrade to"
    vip_stand_in
    allow_unit_actions
    systemctl start keel-vip.service
    local before
    before="$(invocation keel-vip.service)"

    # keel's files under /usr/lib/python3/dist-packages/keel activate
    # keel-overlay-vip's trigger, whose postinst try-restarts the unit
    dpkg -i "$(with_version "$KEEL_DEB" "$(dpkg-deb -f "$KEEL_DEB" Version)+keeltest1")"

    assert_active_state keel-vip.service active
    [ "$(invocation keel-vip.service)" != "$before" ]
    dpkg -i "$KEEL_DEB"
}

@test "etcd restarts through keel's gate, which a node in no cluster passes at once" {
    run systemctl cat etcd.service
    [ "$status" -eq 0 ]
    grep -qx 'ExecStop=+/usr/bin/keel mesh etcd gate stop' <<<"$output"
    grep -qx 'ExecStartPost=-+/usr/bin/keel mesh etcd gate started' <<<"$output"
    grep -qx 'TimeoutStopSec=330' <<<"$output"
    # the gate itself, as root, on this machine in no etcd cluster
    run keel mesh etcd gate stop --wait 0
    [ "$status" -eq 0 ]
    run keel mesh etcd gate started --wait 0
    [ "$status" -eq 0 ]
    systemd_running || return 0
    enable_unit etcd.service
    local started
    started="$(date +%s)"
    systemctl restart etcd.service
    assert_active_state etcd.service active
    # nothing to wait for: well under the gate's own wait
    [ $(( $(date +%s) - started )) -lt 60 ]
}

@test "keel apply can still enable the units: none of them is masked" {
    local unit
    for unit in "${DISABLED_UNITS[@]}"; do
        run systemctl is-enabled "$unit"
        [ "$output" != masked ]
        [ ! -L "/etc/systemd/system/$unit" ]
    done
}
