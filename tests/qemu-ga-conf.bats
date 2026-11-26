#!/usr/bin/env bats
# The QEMU guest agent of the boot layer (handbook decision 0099):
# overlays/keel-boot/etc/qemu/qemu-ga.conf has an allow-list of exactly
# the commands below, and no layer that a container is built from carries
# the file. Where qemu-ga is installed (or QEMU_GA names it), the last tests start it on a unix
# socket with the file and ask it which commands it accepts.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ROOT="$TESTS_DIR/.."
    CONF="$ROOT/overlays/keel-boot/etc/qemu/qemu-ga.conf"
    ALLOWED="guest-fsfreeze-freeze
guest-fsfreeze-freeze-list
guest-fsfreeze-status
guest-fsfreeze-thaw
guest-fstrim
guest-get-disks
guest-get-fsinfo
guest-get-host-name
guest-get-memory-block-info
guest-get-memory-blocks
guest-get-osinfo
guest-get-time
guest-get-timezone
guest-get-vcpus
guest-info
guest-network-get-interfaces
guest-ping
guest-shutdown
guest-sync
guest-sync-delimited"
}

# allow_list: the names of allow-rpcs in the [general] group, sorted
allow_list() {
    awk '/^\[/ { g = $0 } g == "[general]" && /^allow-rpcs=/ { sub(/^allow-rpcs=/, ""); print }' "$CONF" \
        | tr ',' '\n' | sort
}

@test "the boot layer's qemu-ga.conf allows exactly the expected commands" {
    test -f "$CONF"
    run allow_list
    [ "$status" -eq 0 ]
    [ "$output" = "$ALLOWED" ]
}

@test "qemu-ga.conf has one allow-rpcs line, no block-rpcs and no other key" {
    [ "$(grep -c '^allow-rpcs=' "$CONF")" -eq 1 ]
    run ! grep -E '^[[:space:]]*(block-rpcs|fsfreeze-hook|method|path)[[:space:]]*=' "$CONF"
    run ! grep -E '^allow-rpcs=.*[ ;]' "$CONF"
}

@test "no command that writes to the guest is in the allow-list" {
    run ! grep -E '^guest-(exec.*|file-.*|set-.*|ssh-.*|suspend-.*|get-users)$' <<< "$(allow_list)"
}

@test "only the boot layer's overlay has qemu-ga.conf" {
    run find "$ROOT/overlays" "$ROOT/conf" -path '*/etc/qemu/*'
    [ "$status" -eq 0 ]
    [ "$output" = "$CONF" ]
}

@test "the container build applies no keel-boot overlay" {
    run ! grep -E 'COMMON_OVERLAYS.*keel-boot' "$ROOT/mk/turnkey.mk"
}

# start_qga: qemu-ga (QEMU_GA, else from PATH or /usr/sbin) on a unix
# socket with CONF; skips when it is not installed
start_qga() {
    QGA="${QEMU_GA:-$(command -v qemu-ga || echo /usr/sbin/qemu-ga)}"
    [ -x "$QGA" ] || skip "qemu-ga is not installed"
    SOCK="$BATS_TEST_TMPDIR/qga.sock"
    "$QGA" -m unix-listen -p "$SOCK" -c "$CONF" -f "$BATS_TEST_TMPDIR/qga.pid" \
        -t "$BATS_TEST_TMPDIR" 3>&- &
    QGA_PID=$!
    for _ in $(seq 50); do
        [ -S "$SOCK" ] && return 0
        sleep 0.1
    done
    return 1
}

teardown() {
    if [ -n "${QGA_PID:-}" ]; then
        kill "$QGA_PID" 2>/dev/null || true
        wait "$QGA_PID" 2>/dev/null || true
    fi
}

# qga COMMAND...: send each command, print one JSON reply per line
qga() {
    python3 -I - "$SOCK" "$@" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
f = s.makefile("rw")
for cmd in sys.argv[2:]:
    f.write(json.dumps({"execute": cmd}) + "\n")
    f.flush()
    print(f.readline().strip())
PY
}

@test "a running qemu-ga enables exactly the allow-list" {
    start_qga
    run qga guest-info
    [ "$status" -eq 0 ]
    enabled="$(python3 -I -c 'import json, sys
for c in json.loads(sys.stdin.read())["return"]["supported_commands"]:
    if c["enabled"]:
        print(c["name"])' <<< "$output" | sort)"
    [ "$enabled" = "$ALLOWED" ]
}

@test "a running qemu-ga refuses exec, file, password, SSH key and clock commands" {
    start_qga
    for cmd in guest-exec guest-exec-status guest-file-open guest-set-user-password \
            guest-ssh-add-authorized-keys guest-set-time guest-set-vcpus; do
        run qga "$cmd"
        [ "$status" -eq 0 ]
        [[ "$output" == *'"CommandNotFound"'*'has been disabled'* ]]
    done
    run qga guest-ping
    [ "$output" = '{"return": {}}' ]
}
