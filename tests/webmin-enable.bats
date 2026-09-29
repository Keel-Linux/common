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

    export WEBMIN_OPENED=$IMAGE/var/lib/webmin-after-firstboot/opened
    DROPIN=$SYSTEMD_DIR/webmin.service.d/after-firstboot.conf
    ONESHOT=$SYSTEMD_DIR/webmin-after-firstboot.service

    # webmin.service as the webmin package installs it, beside the drop-in
    # the way it is in an image, so that systemd reads the two together.
    # Only the program is swapped for one that exists here, which
    # 'systemd-analyze verify' checks and nothing else depends on.
    sed 's|^ExecStart=/usr/share/webmin/miniserv.pl|ExecStart=/bin/true|' \
        "$FIXTURES/webmin.service" > "$SYSTEMD_DIR/webmin.service"
    UNIT=$SYSTEMD_DIR/webmin.service
}

# next_boot
# What a reboot does to the state these units read: /run is emptied.
next_boot() {
    rm -f "$INITHOOKS_MARKER"
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

@test "systemd accepts webmin.service with the drop-in in place" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run systemd-analyze verify --man=no "$UNIT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the verdict is the merged unit's, the packaged conditions included" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run ! unit_would_start "$UNIT" "$DROPIN"
    touch "$INITHOOKS_MARKER"
    run unit_would_start "$UNIT" "$DROPIN"
    [ "$status" -eq 0 ]

    # a plain condition in the packaged unit would AND with the drop-in's
    printf '[Unit]\nConditionPathExists=%s\n' "$IMAGE/nowhere" >> "$UNIT"
    run ! unit_would_start "$UNIT" "$DROPIN"
}

@test "the first boot opening the interface leaves nothing for later boots to wait on" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    touch "$INITHOOKS_MARKER"
    run run_exec_start "$ONESHOT"
    [ "$status" -eq 0 ]
    grep -qx "systemctl --no-block start webmin.service" "$STUB_LOG"

    next_boot
    run unit_would_start "$UNIT" "$DROPIN"
    [ "$status" -eq 0 ]
}

@test "a boot whose inithooks never finish still has the interface, after one that did" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    touch "$INITHOOKS_MARKER"
    run_exec_start "$ONESHOT"
    next_boot
    next_boot
    [ ! -e "$INITHOOKS_MARKER" ]
    run unit_would_start "$UNIT" "$DROPIN"
    [ "$status" -eq 0 ]
}

@test "the build itself opens nothing: no record of a first boot is left in the image" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$WEBMIN_OPENED" ]
    next_boot
    run ! unit_would_start "$UNIT" "$DROPIN"
}

@test "a first boot that never finishes keeps it shut on the boots after it" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    next_boot
    run ! unit_would_start "$UNIT" "$DROPIN"
    next_boot
    run ! unit_would_start "$UNIT" "$DROPIN"
}

@test "the recovery the script's comment names opens it" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "systemctl start webmin-after-firstboot.service" "$SCRIPT"
    run run_exec_start "$ONESHOT"
    [ "$status" -eq 0 ]
    next_boot
    run unit_would_start "$UNIT" "$DROPIN"
    [ "$status" -eq 0 ]
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
    [ ! -e "$WEBMIN_OPENED" ]
}
