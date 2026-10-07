#!/usr/bin/env bats
# Tests for conf/pgsql, the build time configuration of every recipe that
# includes mk/turnkey/pgsql.mk, run for real against scratch directories.
# pg_dropcluster, pg_createcluster, systemctl, su, psql, createuser and
# createdb are PATH stubs that record what they were called with; the
# created cluster is a scratch postgresql.conf. Nothing here needs root, a
# cluster or a network.
#
# The case these tests exist for is the password. The script gave the
# postgres role ${PGSQL_PASS:=postgres}, so a layer built with nothing
# declared shipped the superuser password 'postgres' to every appliance
# built on it. No conf script sets a database password at build time;
# firstboot.d/35pgsqlpass (overlays/pgsql) sets the real one from DB_PASS.
#
# The script is POSIX shell ("#!/bin/sh -ex") and is run here as "bash -e",
# because kcov measures bash and not dash.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$ROOT/conf/pgsql"
    scratch="$BATS_TEST_TMPDIR"
    export PG_LIB_DIR="$scratch/usr/lib/postgresql"
    export PG_CONF_ROOT="$scratch/etc/postgresql"
    export CALLS="$scratch/calls" SQL="$scratch/sql"
    mkdir -p "$PG_LIB_DIR/17" "$scratch/stubs"
    : > "$CALLS"
    : > "$SQL"
    printf '%s\n' "#password_encryption = on" "shared_buffers = 32MB" > "$scratch/default.conf"

    stub() {
        printf '#!/bin/sh\n%s\n' "$2" > "$scratch/stubs/$1"
        chmod 755 "$scratch/stubs/$1"
    }
    stub pg_dropcluster 'echo "pg_dropcluster $*" >> "$CALLS"; [ -z "$DROP_FAIL" ] || exit 1'
    stub pg_createcluster 'echo "pg_createcluster $*" >> "$CALLS"
[ -z "$CREATE_FAIL" ] || exit 1
mkdir -p "$PG_CONF_ROOT/17/main"
cp "$PG_CONF_ROOT/../../default.conf" "$PG_CONF_ROOT/17/main/postgresql.conf"'
    stub systemctl 'echo "systemctl $*" >> "$CALLS"'
    stub su 'echo "su $*" >> "$CALLS"
while [ $# -gt 0 ]; do case $1 in -c) shift; exec sh -c "$1" ;; esac; shift; done'
    stub psql 'echo "psql $*" >> "$CALLS"; cat >> "$SQL"'
    stub createuser 'echo "createuser $*" >> "$CALLS"'
    stub createdb 'echo "createdb $*" >> "$CALLS"'
    export PATH="$scratch/stubs:$PATH"
    conf="$PG_CONF_ROOT/17/main/postgresql.conf"
    unset PGSQL_PASS
}

@test "the postgres role gets no password at build time" {
    run bash -e "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -i 'password' "$SQL"
    [ "$status" -eq 1 ]
    run grep '^psql' "$CALLS"
    [ "$status" -eq 1 ]
}

@test "a PGSQL_PASS in the build environment reaches no role" {
    PGSQL_PASS=declared-at-build run bash -e "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -r 'declared-at-build' "$SQL" "$CALLS" "$PG_CONF_ROOT"
    [ "$status" -eq 1 ]
}

@test "mk/turnkey/pgsql.mk passes no PGSQL_PASS into the chroot" {
    run grep -E '^[[:space:]]*CONF_VARS.*PGSQL_PASS' "$ROOT/mk/turnkey/pgsql.mk"
    [ "$status" -eq 1 ]
}

@test "the cluster is recreated as UTF-8 for the version that is installed" {
    run bash -e "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'pg_dropcluster --stop 17 main' "$CALLS"
    grep -qx 'pg_createcluster -e UTF-8 17 main' "$CALLS"
}

@test "a cluster that was not there yet is not a failure" {
    DROP_FAIL=1 run bash -e "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "a cluster that cannot be created stops the script" {
    CREATE_FAIL=1 run bash -e "$SCRIPT"
    [ "$status" -ne 0 ]
    run grep -c createuser "$CALLS"
    [ "$output" = 0 ]
}

@test "password encryption is turned on and shared_buffers reduced" {
    run bash -e "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'password_encryption = on' "$conf"
    grep -qx 'shared_buffers = 24MB' "$conf"
}

@test "root gets a superuser role and a database, and the cluster is stopped" {
    run bash -e "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'createuser --superuser root' "$CALLS"
    grep -qx 'createdb root' "$CALLS"
    [ "$(grep '^systemctl' "$CALLS" | tail -1)" = "systemctl stop postgresql" ]
}
