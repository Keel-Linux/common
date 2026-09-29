#!/usr/bin/env bats
# Tests for conf/turnkey.d/dpkg-vendor and the origin file it selects,
# overlays/turnkey.d/dpkg-vendor/etc/dpkg/origins/Keel.
#
# No verdict here reads back the file the conf script wrote (docs/traps.md,
# "Asserting the configuration is not asserting the behaviour"). Every one is
# the answer the real dpkg-vendor gives when it is pointed at the tree the
# script produced, through dpkg's own DPKG_ORIGINS_DIR (Dpkg::Vendor). What is
# asserted is therefore what a bug reporting tool, dpkg-buildpackage or
# anything else asking "who is the vendor of this machine" is told.
#
# Refutations are written "run ! cmd", never a bare "! cmd": bash does not
# apply errexit to a negated command, so a bare one asserts nothing unless
# it happens to be the last command of its test.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO="$(cd "$TESTS_DIR/.." && pwd)"
    SCRIPT="$REPO/conf/turnkey.d/dpkg-vendor"
    SHIPPED="$REPO/overlays/turnkey.d/dpkg-vendor/etc/dpkg/origins"

    # the origins directory of an image being built: what the overlay ships,
    # plus the Debian file dpkg itself installs, which Parent: resolves to
    export DPKG_ORIGINS_DIR="$BATS_TEST_TMPDIR/origins"
    mkdir -p "$DPKG_ORIGINS_DIR"
    cp -a "$SHIPPED"/. "$DPKG_ORIGINS_DIR/"
    cat > "$DPKG_ORIGINS_DIR/debian" <<'DEBIAN'
Vendor: Debian
Vendor-URL: https://www.debian.org/
Bugs: debbugs://bugs.debian.org
DEBIAN

    # DEB_VENDOR would override the default symlink, which is the thing under
    # test; dpkg-vendor is the real one from dpkg-dev
    unset DEB_VENDOR
    command -v dpkg-vendor >/dev/null || {
        echo "dpkg-vendor not found (apt-get install dpkg-dev)" >&2
        return 1
    }
}

# the real dpkg-vendor, reading the tree the conf script just arranged
vendor() {
    env -u DEB_VENDOR DPKG_ORIGINS_DIR="$DPKG_ORIGINS_DIR" dpkg-vendor "$@"
}

# --------------------------------------------------------- what it answers

@test "a vendor query answers Keel" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run vendor --query Vendor
    [ "$status" -eq 0 ]
    [ "$output" = Keel ]
}

@test "a vendor query does not answer TurnKey" {
    "$SCRIPT"
    run vendor --query Vendor
    [ "$output" != TurnKey ]
    run vendor --is TurnKey
    [ "$status" -ne 0 ]
}

@test "the vendor is Keel by dpkg's own --is test" {
    "$SCRIPT"
    run vendor --is Keel
    [ "$status" -eq 0 ]
}

@test "bug reports are addressed to our own tracker" {
    "$SCRIPT"
    run vendor --query Bugs
    [ "$status" -eq 0 ]
    [ "$output" = "https://github.com/Keel-Linux/tracker/issues" ]
}

@test "nothing a vendor query answers names a turnkeylinux host" {
    "$SCRIPT"
    for field in Vendor Vendor-URL Bugs Parent; do
        run vendor --query "$field"
        [[ "$output" != *turnkeylinux* ]]
    done
}

@test "the vendor URL is our own site" {
    "$SCRIPT"
    run vendor --query Vendor-URL
    [ "$output" = "https://keellinux.org/" ]
}

@test "the vendor still derives from Debian, so dpkg-dev behaves as before" {
    "$SCRIPT"
    run vendor --derives-from Debian
    [ "$status" -eq 0 ]
}

@test "the vendor does not claim to derive from Ubuntu" {
    "$SCRIPT"
    run vendor --derives-from Ubuntu
    [ "$status" -ne 0 ]
}

# ------------------------------------------------------------- the script

@test "the TurnKey origin file is not shipped at all" {
    [ ! -e "$SHIPPED/TurnKey" ]
    [ -f "$SHIPPED/Keel" ]
}

@test "running it twice leaves the same answer" {
    "$SCRIPT"
    "$SCRIPT"
    run vendor --query Vendor
    [ "$status" -eq 0 ]
    [ "$output" = Keel ]
}

@test "an inherited default pointing at TurnKey is replaced" {
    # the upgrade path: a parent layer built before this change
    printf 'Vendor: TurnKey\nVendor-URL: https://www.turnkeylinux.org/\nBugs: https://github.com/turnkeylinux/tracker/issues\nParent: Debian\n' \
        > "$DPKG_ORIGINS_DIR/TurnKey"
    ln -sf "$DPKG_ORIGINS_DIR/TurnKey" "$DPKG_ORIGINS_DIR/default"
    run vendor --query Vendor
    [ "$output" = TurnKey ]
    "$SCRIPT"
    run vendor --query Vendor
    [ "$output" = Keel ]
}

@test "an inherited TurnKey origin file is removed, not only unselected" {
    # an overlay only adds, so a parent layer built before this change
    # leaves its TurnKey file on the image; dpkg still knows that vendor by
    # name until the file is gone
    printf 'Vendor: TurnKey\nVendor-URL: https://www.turnkeylinux.org/\nBugs: https://github.com/turnkeylinux/tracker/issues\nParent: Debian\n' \
        > "$DPKG_ORIGINS_DIR/TurnKey"
    ln -sf "$DPKG_ORIGINS_DIR/TurnKey" "$DPKG_ORIGINS_DIR/default"
    run dpkg-vendor --vendor TurnKey --query Bugs
    [ "$output" = https://github.com/turnkeylinux/tracker/issues ]
    "$SCRIPT"
    run dpkg-vendor --vendor TurnKey --query Bugs
    [ "$status" -ne 0 ]
    [[ "$output" == *"vendor TurnKey doesn't exist"* ]]
    run vendor --query Vendor
    [ "$output" = Keel ]
}

@test "a default that is a regular file rather than a symlink is replaced" {
    cp "$DPKG_ORIGINS_DIR/Keel" "$DPKG_ORIGINS_DIR/default"
    printf 'Vendor: Whoever\n' > "$DPKG_ORIGINS_DIR/default"
    "$SCRIPT"
    run vendor --query Vendor
    [ "$output" = Keel ]
}

@test "a default that is a directory is replaced" {
    mkdir -p "$DPKG_ORIGINS_DIR/default"
    "$SCRIPT"
    run vendor --query Vendor
    [ "$output" = Keel ]
}

@test "it refuses when the origin file it points at is missing" {
    rm -f "$DPKG_ORIGINS_DIR/Keel"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *Keel* ]]
    [ ! -e "$DPKG_ORIGINS_DIR/default" ]
}

@test "it refuses when the origins directory is missing" {
    rm -rf "$DPKG_ORIGINS_DIR"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *origins* ]]
}
