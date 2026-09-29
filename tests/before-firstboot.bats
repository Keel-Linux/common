#!/usr/bin/env bats
# What a freshly built image lets through between the end of the build and
# the end of the first boot, when no password has been set on it yet.
#
# The conf scripts that decide it are run over one scratch image in the
# order the build runs them, and the image is then asked the only question
# worth asking of it: can anybody get in.
#
# No single script owns the answer. rootpass decides what the account
# carries, webmin-pam decides what the stack makes of it and webmin-enable
# decides whether the interface is listening at all, so they are tested
# together as well as apart.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    CONF_DIR="$TESTS_DIR/../conf/turnkey.d"
    scratch_image

    export INITHOOKS_MARKER=$IMAGE/run/inithooks-complete
    export INITHOOKS_RUN=$IMAGE/usr/lib/inithooks/run
    mkdir -p "$IMAGE/run" "$IMAGE/usr/lib/inithooks"
    touch "$INITHOOKS_RUN"

    DROPIN=$SYSTEMD_DIR/webmin.service.d/after-firstboot.conf
    unset CHROOT_ONLY ROOT_PASS
}

# build_image
# Runs the conf scripts of this change in the order fab runs a conf
# directory, which is the order their names sort in.
build_image() {
    local script
    for script in $(printf '%s\n' rootpass webmin-enable webmin-pam | sort); do
        "$CONF_DIR/$script"
    done
}

@test "no password gets in before the first boot has set one" {
    build_image
    run nothing_authenticates
    [ "$status" -eq 0 ]
}

@test "and the interface is not up to be asked" {
    build_image
    run ! unit_would_start "$DROPIN"
}

@test "and it stays that way for as long as the first boot takes" {
    build_image
    run ! unit_would_start "$DROPIN"
    run nothing_authenticates
    [ "$status" -eq 0 ]

    passwd --unlock root
    run nothing_authenticates
    [ "$status" -eq 0 ]
    run ! unit_would_start "$DROPIN"
}

@test "and opens when the first boot has set a password" {
    build_image
    echo 'root:hunter2' | chpasswd
    touch "$INITHOOKS_MARKER"

    run unit_would_start "$DROPIN"
    [ "$status" -eq 0 ]
    run authenticates "hunter2"
    [ "$status" -eq 0 ]
    run refuses ""
    [ "$status" -eq 0 ]
}

@test "a build given a root password is held shut the same way" {
    export ROOT_PASS=s3cret
    build_image
    run ! unit_would_start "$DROPIN"
    run authenticates "s3cret"
    [ "$status" -eq 0 ]
    run refuses ""
    [ "$status" -eq 0 ]
}
