#!/usr/bin/env bats
# Tests for conf/turnkey.d/motd: the message of the day an operator reads
# at login names no TurnKey service or address.
#
# The system information drop-in runs turnkey-sysinfo's motd script, which
# ends, when run as root, with what tklbam-status prints: a block telling
# the operator to link the machine to a TurnKey Hub account. The drop-in
# keeps the welcome and the system information and leaves that block out.
# SYSINFO_STUB prints what the script printed on the Web image, 2026-10-01
# (screens/014 of the maintainer's gallery), with and without the block.

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../conf/turnkey.d/motd"
    export MOTD_DIR=$BATS_TEST_TMPDIR/etc/update-motd.d
    export MOTD=$BATS_TEST_TMPDIR/etc/motd
    export SYSINFO_MOTD=$BATS_TEST_TMPDIR/sysinfo-motd
    mkdir -p "$(dirname "$MOTD")"
    printf 'The programs included with the Debian GNU/Linux system\n' > "$MOTD"
    with_backup_block
}

with_backup_block() {
    cat > "$SYSINFO_MOTD" <<'EOF'
#!/bin/sh
cat <<'OUT'
Welcome to Web, Debian 13/Trixie

  System information for Thu Oct 01 23:22:12 2026 (UTC+0000)

    System load:  0.16               Memory usage:  24.0%
    Processes:    26                 Swap usage:    6.5%
    Usage of /:   27.5% of 29.36GB   IP address for eth0: 10.0.3.186

  TKLBAM (Backup and Migration):  NOT INITIALIZED

    To initialize TKLBAM, run the "tklbam-init" command to link this
    system to your TurnKey Hub account. For details see the man page or
    go to:

        https://www.turnkeylinux.org/tklbam

OUT
EOF
    chmod +x "$SYSINFO_MOTD"
}

without_backup_block() {
    cat > "$SYSINFO_MOTD" <<'EOF'
#!/bin/sh
cat <<'OUT'
Welcome to Web, Debian 13/Trixie

  System information for Thu Oct 01 23:22:12 2026 (UTC+0000)

    System load:  0.16               Memory usage:  24.0%
    Usage of /:   27.5% of 29.36GB   IP address for eth0: 10.0.3.186

OUT
EOF
    chmod +x "$SYSINFO_MOTD"
}

@test "the system information keeps the welcome and every figure" {
    "$SCRIPT"
    run "$MOTD_DIR/00-turnkey-sysinfo"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Welcome to Web, Debian 13/Trixie" ]
    [[ "$output" == *"System load:  0.16"* ]]
    [[ "$output" == *"Processes:    26"* ]]
    [[ "$output" == *"IP address for eth0: 10.0.3.186"* ]]
}

@test "the system information leaves out the TurnKey backup block" {
    "$SCRIPT"
    run "$MOTD_DIR/00-turnkey-sysinfo"
    [ "$status" -eq 0 ]
    [[ "$output" != *TKLBAM* ]]
    [[ "$output" != *TurnKey* ]]
    [[ "$output" != *turnkeylinux* ]]
}

@test "the system information ends with one blank line, block or not" {
    "$SCRIPT"
    "$MOTD_DIR/00-turnkey-sysinfo" > "$BATS_TEST_TMPDIR/with"
    without_backup_block
    "$SCRIPT"
    "$MOTD_DIR/00-turnkey-sysinfo" > "$BATS_TEST_TMPDIR/without"
    for out in with without; do
        tail -n 2 "$BATS_TEST_TMPDIR/$out" > "$BATS_TEST_TMPDIR/tail"
        grep -q '10\.0\.3\.186$' <(head -n 1 "$BATS_TEST_TMPDIR/tail")
        [ "$(tail -n 1 "$BATS_TEST_TMPDIR/tail")" = "" ]
    done
}

@test "the confconsole line points at Keel's confconsole, not TurnKey's" {
    "$SCRIPT"
    run env TERM=dumb "$MOTD_DIR/08-turnkey-confconsole"
    [ "$status" -eq 0 ]
    [[ "$output" == *"confconsole"* ]]
    [[ "$output" == *"https://github.com/Keel-Linux/confconsole"* ]]
    [[ "$output" != *turnkeylinux* ]]
}

@test "the confconsole line works without TERM" {
    "$SCRIPT"
    run env -u TERM "$MOTD_DIR/08-turnkey-confconsole"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://github.com/Keel-Linux/confconsole"* ]]
}

@test "no drop-in names TurnKey or its site" {
    "$SCRIPT"
    run grep -ril 'turnkeylinux\|tklbam' "$MOTD_DIR"
    [ "$status" -eq 1 ]
}

@test "every drop-in is executable and Debian's disclaimer is emptied" {
    touch "$MOTD_DIR/00-header" 2>/dev/null || { mkdir -p "$MOTD_DIR"; touch "$MOTD_DIR/00-header"; }
    "$SCRIPT"
    [ ! -e "$MOTD_DIR/00-header" ]
    for f in "$MOTD_DIR"/*; do
        [ -x "$f" ]
    done
    [ -f "$MOTD" ]
    [ ! -s "$MOTD" ]
}
