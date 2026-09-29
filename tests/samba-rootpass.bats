#!/usr/bin/env bats
# Tests for conf/samba-rootpass: the same question as rootpass.bats, for the
# copy of it the Samba appliances run, and what it hands smbpasswd.
#
# The verdict is the real pam_unix's (helpers.bash); the shadow tools and
# smbpasswd are stubs.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../conf/samba-rootpass"
    scratch_image
    unset ROOT_PASS
}

@test "no password gets root in when the build sets none, through any stack" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run nothing_authenticates root "$PAM_WEBMIN"
    [ "$status" -eq 0 ]
    run nothing_authenticates root "$PAM_COMMON_AUTH"
    [ "$status" -eq 0 ]
}

@test "the account is unlocked first, and the field left is one unlock accepts" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(head -1 "$STUB_LOG")" = "passwd --unlock root" ]
    [ "$(field_of root)" = '*' ]
    run passwd --unlock root
    [ "$status" -eq 0 ]
}

@test "the Samba account is added with no password when the build sets none" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$STUB_LOG")" = "smbpasswd -a -n root" ]
}

@test "a build time ROOT_PASS is the password for both, and nothing else is" {
    export ROOT_PASS=s3cret
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run authenticates s3cret
    [ "$status" -eq 0 ]
    run refuses ""
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$STUB_LOG")" = "smbpasswd -a -s root" ]
    [ "$(cat "$STUB_LOG.stdin")" = "$(printf 's3cret\ns3cret')" ]
}

@test "a ROOT_PASS holding a glob character is set as written" {
    mkdir -p "$IMAGE/build"
    touch "$IMAGE/build/root:pass"
    cd "$IMAGE/build"
    export ROOT_PASS='p*ss'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run authenticates 'p*ss'
    [ "$status" -eq 0 ]
    run refuses 'pass'
    [ "$status" -eq 0 ]
}

@test "the build password is not written to the build log" {
    export ROOT_PASS='n0t-in-the-log'
    run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output$stderr" != *"n0t-in-the-log"* ]]
}
