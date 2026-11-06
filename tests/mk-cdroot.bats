#!/usr/bin/env bats
# The cdroot of the ISO that mk/turnkey.mk and mk/turnkey-desktop.mk select:
# gfxboot-keel of Keel-Linux/cdroots, the boot menu with the Keel mark, not
# gfxboot-turnkey, the boot menu with the TurnKey Linux logo.
#
# make reads the makefile under test through tests/mk/harness.mk, with the
# empty product.mk of tests/mk in place of fab's.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STUBS="$BATS_TEST_DIRNAME/mk"
    WORK="$BATS_TEST_TMPDIR/product"
    mkdir -p "$WORK"
}

# cdroot_of MAKEFILE [VAR=VALUE ...]: the CDROOT that the makefile gives
# to fab, from a product directory.
cdroot_of() {
    local mk=$1
    shift
    run make --no-print-directory -C "$WORK" -f "$STUBS/harness.mk" \
        MK="$ROOT/mk/$mk" FAB_SHARE_PATH="$STUBS" \
        --eval 'print-cdroot: ; @echo $(CDROOT)' "$@" print-cdroot
}

@test "turnkey.mk selects the Keel boot menu" {
    cdroot_of turnkey.mk
    [ "$status" -eq 0 ]
    [ "$output" = gfxboot-keel ]
}

@test "turnkey-desktop.mk selects the Keel boot menu" {
    cdroot_of turnkey-desktop.mk
    [ "$status" -eq 0 ]
    [ "$output" = gfxboot-keel ]
}

@test "a product can still select a different cdroot" {
    # from the environment, not the command line: a command line value
    # overrides any assignment, an environment value only a ?= assignment
    export CDROOT=generic
    cdroot_of turnkey.mk
    [ "$status" -eq 0 ]
    [ "$output" = generic ]
}
