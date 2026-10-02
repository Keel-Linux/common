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

# A build time ROOT_PASS was shared by every copy of the image; the image
# ships both accounts without one whatever it says (mk/turnkey/seal-root).

@test "a build time ROOT_PASS is ignored for both accounts" {
    export ROOT_PASS=s3cret
    run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(field_of root)" = '*' ]
    run refuses s3cret
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$STUB_LOG")" = "smbpasswd -a -n root" ]
    [[ "$stderr" == *"ROOT_PASS is ignored"* ]]
}

@test "the build password is not written to the build log" {
    export ROOT_PASS='n0t-in-the-log'
    run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output$stderr" != *"n0t-in-the-log"* ]]
}
