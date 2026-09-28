#!/usr/bin/env bats
# Tests for conf/turnkey.d/webmin-enable: when the web interface of a
# freshly built image is allowed to start.
#
# The verdict on the conditions is systemd's own, taken from
# 'systemd-analyze condition'; the unit files are handed to
# 'systemd-analyze verify' so that systemd, and not a reader, says they
# parse.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../conf/turnkey.d/webmin-enable"
    scratch_image

    export INITHOOKS_MARKER=$IMAGE/run/inithooks-complete
    export INITHOOKS_RUN=$IMAGE/usr/lib/inithooks/run
    mkdir -p "$IMAGE/run" "$IMAGE/usr/lib/inithooks"
    touch "$INITHOOKS_RUN"

    DROPIN=$SYSTEMD_DIR/webmin.service.d/after-firstboot.conf
}

@test "webmin does not start while the first boot scripts have not run" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run ! unit_would_start "$DROPIN"
}

@test "webmin starts once they report they have" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    touch "$INITHOOKS_MARKER"
    run unit_would_start "$DROPIN"
    [ "$status" -eq 0 ]
}

@test "an image with no inithooks is not left without a web interface" {
    rm "$INITHOOKS_RUN"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run unit_would_start "$DROPIN"
    [ "$status" -eq 0 ]
}

@test "systemd accepts the units the script writes" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run systemd-analyze verify \
        "$SYSTEMD_DIR/webmin-after-firstboot.path" \
        "$SYSTEMD_DIR/webmin-after-firstboot.service"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the marker is what the path unit waits for, and it fires once" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    unit=$SYSTEMD_DIR/webmin-after-firstboot.path
    grep -qx "PathExists=$INITHOOKS_MARKER" "$unit"
    grep -qx "Unit=webmin-after-firstboot.service" "$unit"
    grep -qx "RemainAfterExit=yes" \
        "$SYSTEMD_DIR/webmin-after-firstboot.service"
}

@test "webmin and the path unit are the two units enabled" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    diff - "$STUB_LOG" <<'EXPECTED'
systemctl enable webmin
systemctl enable webmin-after-firstboot.path
EXPECTED
}

@test "running it again leaves the same image" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    first="$(cat "$DROPIN" "$SYSTEMD_DIR"/webmin-after-firstboot.*)"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DROPIN" "$SYSTEMD_DIR"/webmin-after-firstboot.*)" = "$first" ]
}
