#!/usr/bin/env bats
# Tests for conf/turnkey.d/rootpass: what a caller can get in with, in the
# image the script leaves behind.
#
# The verdict is pam_unix's, over the real crypt(); the shadow tools are
# stubs. See helpers.bash.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../conf/turnkey.d/rootpass"
    scratch_image
    unset CHROOT_ONLY ROOT_PASS
}

@test "no password gets root in when the build sets none" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run nothing_authenticates
    [ "$status" -eq 0 ]
}

@test "the empty password is refused although the stack still allows a blank one" {
    stack_allows_blank
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run refuses ""
    [ "$status" -eq 0 ]
}

@test "the field left behind is one passwd --unlock accepts" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    before="$(field_of root)"
    run passwd --unlock root
    [ "$status" -eq 0 ]
    [ "$(field_of root)" = "$before" ]
    run nothing_authenticates
    [ "$status" -eq 0 ]
}

@test "a field of '!' is the one passwd --unlock refuses, which is why it is not used" {
    printf 'root:!:20718:0:99999:7:::\n' > "$SHADOW_FILE"
    run passwd --unlock root
    [ "$status" -eq 3 ]
    [[ "$output" == *"passwordless account"* ]]
    [ "$(field_of root)" = '!' ]
}

@test "the password the first boot sets over it works" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    echo 'root:hunter2' | chpasswd
    run authenticates "hunter2"
    [ "$status" -eq 0 ]
    run refuses ""
    [ "$status" -eq 0 ]
    run refuses "hunter3"
    [ "$status" -eq 0 ]
}

# A build time ROOT_PASS was a password every copy of the image shared, and
# the first boot cannot tell it from one set when the container was created
# (mk/turnkey/seal-root). The image ships root locked whatever it says.

@test "a build time ROOT_PASS is ignored and root stays locked" {
    export ROOT_PASS=s3cret
    run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(field_of root)" = '*' ]
    run refuses "s3cret"
    [ "$status" -eq 0 ]
    run nothing_authenticates
    [ "$status" -eq 0 ]
}

@test "an ignored ROOT_PASS is said, without its value" {
    export ROOT_PASS='n0t-in-the-log'
    run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"ROOT_PASS is ignored"* ]]
    [[ "$output$stderr" != *"n0t-in-the-log"* ]]
}

@test "a chroot only build locks the account instead" {
    export CHROOT_ONLY=y
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_LOG")" = "passwd --lock root" ]
    [[ "$(field_of root)" == '!'* ]]
    run nothing_authenticates
    [ "$status" -eq 0 ]
}

@test "the account database is touched once, with usermod" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_LOG")" = "usermod -p * root" ]
}
