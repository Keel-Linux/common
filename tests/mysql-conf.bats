#!/usr/bin/env bats
# Tests for conf/mysql, the build time configuration of every recipe that
# includes mk/turnkey/mysql.mk, run for real against a scratch init script
# directory. service and mysql are PATH stubs that record their calls, and a
# tkl-bashlib stub records any dl(). Nothing here needs root, a database or
# a network.
#
# The case these tests exist for is mysqltuner. The script downloaded it and
# its two data files from the master branch of jmrenouard/MySQLTuner-perl,
# unpinned and unchecked. Debian trixie packages it, so plans/turnkey/mysql
# names it and the script fetches nothing.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$ROOT/conf/mysql"
    export INITD="$BATS_TEST_TMPDIR/etc/init.d"
    export TKL_BASHLIB="$BATS_TEST_TMPDIR/tkl-bashlib"
    export CALLS="$BATS_TEST_TMPDIR/calls" SQL="$BATS_TEST_TMPDIR/sql"
    mkdir -p "$INITD" "$TKL_BASHLIB" "$BATS_TEST_TMPDIR/stubs"
    : > "$INITD/mariadb"
    : > "$CALLS"
    printf 'dl() { echo "dl $*" >> "$CALLS"; }\n' > "$TKL_BASHLIB/init.sh"
    printf '#!/bin/sh\necho "service $*" >> "$CALLS"\n[ -z "$SERVICE_FAIL" ] || exit 1\n' \
        > "$BATS_TEST_TMPDIR/stubs/service"
    printf '#!/bin/sh\necho "mysql $*" >> "$CALLS"\ncat >> "$SQL"\n[ -z "$MYSQL_FAIL" ] || exit 1\n' \
        > "$BATS_TEST_TMPDIR/stubs/mysql"
    chmod 755 "$BATS_TEST_TMPDIR/stubs/"*
    export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
}

@test "plans/turnkey/mysql installs Debian's mysqltuner" {
    grep -qx 'mysqltuner' "$ROOT/plans/turnkey/mysql"
}

@test "downloads nothing" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep '^dl ' "$CALLS"
    [ "$status" -eq 1 ]
}

@test "fetches nothing from the network at build time" {
    # Comments are left out, so the reason can still be written down.
    run bash -c "sed 's/^[[:space:]]*#.*//' '$SCRIPT' \
        | grep -En 'https?://|(^|[^[:alnum:]_])(dl|curl|wget|gh_releases)([^[:alnum:]_]|$)'"
    [ "$status" -eq 1 ]
}

@test "sets no database password at build time" {
    run bash -c "sed 's/^[[:space:]]*#.*//' '$SCRIPT' \
        | grep -Ein \"password[[:space:]]+(E?'|\\\"|\\\$)|identified[[:space:]]+(by|via|with)|mysqladmin.*password|[A-Z_]*_PASS\\b\""
    [ "$status" -eq 1 ]
}

@test "does not need tkl-bashlib, whose only use was the download" {
    rm -f "$TKL_BASHLIB/init.sh"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "links the init script Debian no longer ships" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(readlink "$INITD/mysql")" = "$INITD/mariadb" ]
}

@test "starts the server, secures it, and stops it" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    mapfile -t calls < "$CALLS"
    [ "${calls[0]}" = "service mysql start" ]
    [[ "${calls[1]}" == mysql* ]]
    [ "${calls[2]}" = "service mysql stop" ]
    [ "${#calls[@]}" -eq 3 ]
    grep -q "DELETE FROM user WHERE User=''" "$SQL"
    grep -q "DELETE FROM user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')" "$SQL"
    grep -q 'DROP DATABASE IF EXISTS test;' "$SQL"
}

@test "fails when the server does not start" {
    SERVICE_FAIL=1 run "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -s "$SQL" ]
}

@test "fails when the server refuses the SQL" {
    MYSQL_FAIL=1 run "$SCRIPT"
    [ "$status" -ne 0 ]
    run grep -c '^service mysql stop$' "$CALLS"
    [ "$output" = 0 ]
}
