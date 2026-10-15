#!/usr/bin/env bats
# Tests for overlays/pgsql/usr/lib/inithooks/firstboot.d/35pgsqlpass: the
# postgres password of the first boot, and a first boot that nobody can
# answer (keel#155, item 6).
#
# A screen that nobody can answer holds the first boot for ever. Then
# 98finalize never sets RUN_FIRSTBOOT=false, and the next boot runs every
# first boot hook again: new SSH host keys, a new root password state.
# pgsqlconf.py is a stub that records its arguments; lib/console.sh is the
# contract of inithooks: console_unattended and console_skipped.

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    HOOK="$TESTS_DIR/../overlays/pgsql/usr/lib/inithooks/firstboot.d/35pgsqlpass"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/inithooks/bin" "$T/inithooks/lib"
    cat > "$T/default" <<DEFAULT
INITHOOKS_CONF=$T/inithooks.conf
INITHOOKS_PATH=$T/inithooks
INITHOOKS_LOGFILE=$T/inithooks.log
DEFAULT
    export INITHOOKS_DEFAULT="$T/default"
    printf '#!/bin/bash\necho "$*" >> "%s/pgsqlconf.calls"\n' "$T" > "$T/inithooks/bin/pgsqlconf.py"
    chmod +x "$T/inithooks/bin/pgsqlconf.py"
    cat > "$T/inithooks/lib/console.sh" <<'CONSOLE'
console_unattended() { [[ "${INITHOOKS_UNATTENDED:-no}" != "no" ]]; }
console_skipped() {
    echo "[$1] not asked, nobody can answer ($INITHOOKS_UNATTENDED): $2" >&2
    echo "INFO: [$1] not asked, nobody can answer ($INITHOOKS_UNATTENDED): $2" >> "$INITHOOKS_LOGFILE"
}
CONSOLE
    unset DB_PASS INITHOOKS_UNATTENDED
}

@test "nobody can answer and no DB_PASS: nothing is asked, the hook says so and succeeds" {
    INITHOOKS_UNATTENDED="the console has no size, nobody is attached to it" run "$HOOK"
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/pgsqlconf.calls" ]
    [[ "$output" == *"[35pgsqlpass] not asked, nobody can answer (the console has no size"* ]]
    grep -q '^INFO: \[35pgsqlpass\] not asked' "$BATS_TEST_TMPDIR/inithooks.log"
}

@test "DB_PASS in the inithooks conf sets the password with no screen, attended or not" {
    echo "DB_PASS='s3cret-Pass'" > "$BATS_TEST_TMPDIR/inithooks.conf"
    INITHOOKS_UNATTENDED="there is no terminal" run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/pgsqlconf.calls")" = "--user=postgres --pass=s3cret-Pass" ]
}

@test "somebody can answer and no DB_PASS: pgsqlconf.py asks" {
    INITHOOKS_UNATTENDED=no run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/pgsqlconf.calls")" = "--user=postgres --pass=" ]
}
