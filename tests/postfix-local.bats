#!/usr/bin/env bats
# Tests for conf/turnkey.d/postfix-local.
#
# ss, postconf, postmulti and systemctl are replaced by stubs from
# tests/stubs that record their arguments in STUB_LOG; the script never
# reaches the real postfix or systemd.

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../conf/turnkey.d/postfix-local"
    export PATH="$TESTS_DIR/stubs:$PATH"
    export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
    : > "$STUB_LOG"
    unset STUB_POSTCONF_FAIL
    export HOSTNAME=mail.example.com
    export STUB_SS_OUTPUT="$(listening 22)"
}

# ss -tlnp output with the given ports listening on IPv6 and IPv4
listening() {
    local port
    echo 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
    for port in "$@"; do
        echo "LISTEN 0      128    [::]:$port          [::]:*            users:((\"sshd\",pid=612,fd=4))"
        echo "LISTEN 0      128    0.0.0.0:$port       0.0.0.0:*         users:((\"sshd\",pid=612,fd=3))"
    done
}

logged() {
    grep -qF -- "$1" "$STUB_LOG"
}

@test "fails when HOSTNAME is empty" {
    HOSTNAME= run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$output" = "'postfix-local' Error: Hostname not defined" ]
    [ ! -s "$STUB_LOG" ]
}

@test "takes the hostname bash sets when HOSTNAME is not in the environment" {
    run env -u HOSTNAME "$SCRIPT"
    [ "$status" -eq 0 ]
    logged "postconf -e myhostname=$(uname -n)"
}

@test "asks ss for listening TCP sockets with their processes" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(head -1 "$STUB_LOG")" = "ss -tlnp" ]
}

@test "fails when port 25 is in use" {
    export STUB_SS_OUTPUT="$(listening 22 25)"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$output" = "'postfix-local' Error: Port 25 is already in use - must be available to set up postfix (the chroot shares the build host network; e.g. 'systemctl stop postfix' on the build host)" ]
    [ "$(cat "$STUB_LOG")" = "ss -tlnp" ]
}

@test "fails when port 25 is in use on IPv6 only" {
    export STUB_SS_OUTPUT="$(listening 22)
LISTEN 0      100    [2001:db8::25]:25   [::]:*            users:((\"master\",pid=910,fd=13))"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Port 25 is already in use"* ]]
    ! logged postconf
}

@test "configures postfix when port 25 is free" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    diff - "$STUB_LOG" <<'EXPECTED'
ss -tlnp
postconf -e inet_interfaces=localhost
postconf -e myhostname=mail.example.com
postconf -e smtpd_banner=$myhostname ESMTP
postconf -e smtpd_tls_auth_only=yes
postconf -e tls_preempt_cipherlist=no
postconf -e smtpd_tls_mandatory_protocols=>=TLSv1.2
postconf -e smtpd_tls_protocols=>=TLSv1.2
postconf -e smtp_tls_mandatory_ciphers=medium
postconf -e smtpd_tls_mandatory_ciphers=medium
postconf -e tls_medium_cipherlist=ZZ_SSL_CIPHERS
postmulti -x postfix start
systemctl enable postfix@-.service
postmulti -x postfix stop
EXPECTED
}

@test "stops at the first failing postconf" {
    export STUB_POSTCONF_FAIL=myhostname
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    logged "postconf -e myhostname=mail.example.com"
    ! logged smtpd_banner
    ! logged postmulti
}
