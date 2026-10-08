#!/usr/bin/env bats
# The plans of handbook decision 0052: a layer built from turnkey/base is a
# container's and has no kernel, initrd, firmware, bootloader or installer;
# plans/keel-boot, which only the boot layer of the ISO installs, has them.
# The plans are put through cpp as fab-plan-resolve does, with the defines
# of an amd64 Debian build and without CHROOT_ONLY, which Keel's layers are
# not built with. The patterns are those keel assemble refuses in a
# template (keel.layers.container.MACHINE_ONLY).

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PLANS="$TESTS_DIR/../plans"
    MACHINE_ONLY='^(linux-image-.*|linux-headers-.*|linux-base|initramfs-tools.*|dracut.*|klibc-utils|libklibc|live-boot.*|live-config.*|live-tools|tkl-installer|firmware-.*|.*-microcode|grub.*|shim.*|efibootmgr|mokutil|efivar|syslinux.*|isolinux|extlinux|os-prober|hdparm|qemu-guest-agent|acpi-support-base|acpid|jitterentropy-rngd)$'
}

# resolve PLAN: the package names PLAN lists, one per line
resolve() {
    cpp -P -undef -nostdinc -I "$PLANS" -D DEBIAN=y -D AMD64=y "$PLANS/$1" \
        | sed 's/#.*//' | awk 'NF { print $1 }' | sort -u
}

@test "a layer built from turnkey/base has no package only a machine boots with" {
    run --separate-stderr resolve turnkey/base
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    run ! grep -E "$MACHINE_ONLY" <<< "$output"
}

@test "turnkey/base still installs systemd as the init" {
    run resolve turnkey/base
    [ "$status" -eq 0 ]
    grep -qx systemd <<< "$output"
    grep -qx systemd-sysv <<< "$output"
}

@test "the boot layer has the kernel, the initrd, GRUB, the live boot and the installer" {
    run --separate-stderr resolve keel-boot
    [ "$status" -eq 0 ]
    for name in linux-image-amd64 initramfs-tools firmware-linux-free grub-pc \
            live-boot isolinux tkl-installer efivar qemu-guest-agent; do
        grep -qx "$name" <<< "$output"
    done
}

@test "every package taken out of turnkey/base is in the boot layer" {
    for name in grub-pc tkl-installer efivar eject jitterentropy-rngd \
            qemu-guest-agent acpi-support-base; do
        resolve keel-boot | grep -qx "$name"
        run ! grep -qx "$name" <<< "$(resolve turnkey/base)"
    done
}

@test "only the boot layer's conf and overlay touch GRUB's configuration" {
    run ! grep -rl '/etc/default/grub' "$TESTS_DIR/../conf/turnkey.d"
    run ! test -e "$TESTS_DIR/../overlays/turnkey.d/grub"
    grep -q /etc/default/grub "$TESTS_DIR/../conf/keel-boot/grub-iface-naming"
    test -f "$TESTS_DIR/../overlays/keel-boot/etc/default/grub"
}

# stub_sed: sed records its arguments instead of editing the host
stub_sed() {
    mkdir -p "$BATS_TEST_TMPDIR/stubs"
    printf '#!/bin/sh\necho "sed $*" >> "%s/calls"\n' "$BATS_TEST_TMPDIR" \
        > "$BATS_TEST_TMPDIR/stubs/sed"
    chmod +x "$BATS_TEST_TMPDIR/stubs/sed"
    PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
}

@test "a container still keeps the journal off the console, which grub-debug used to do" {
    stub_sed
    unset DEBUG
    run "$TESTS_DIR/../conf/turnkey.d/journald-no-wall"
    [ "$status" -eq 0 ]
    grep -q 'ForwardToWall.*/etc/systemd/journald.conf$' "$BATS_TEST_TMPDIR/calls"
    run "$TESTS_DIR/../conf/keel-boot/grub-debug"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
}

@test "a debug build adds the debug options to GRUB and leaves the journal alone" {
    stub_sed
    export DEBUG=y
    run "$TESTS_DIR/../conf/turnkey.d/journald-no-wall"
    [ "$status" -eq 0 ]
    run "$TESTS_DIR/../conf/keel-boot/grub-debug"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
    grep -q 'debug ignore_loglevel.* /etc/default/grub$' "$BATS_TEST_TMPDIR/calls"
}
