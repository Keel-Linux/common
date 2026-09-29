#!/usr/bin/env bats
# What pam_unix itself does with the password fields and the option these
# conf scripts decide, asked of the real module (tests/pam-authenticate).
#
# These are not tests of this repository's scripts. They pin the facts the
# other suites rest on, so that a libpam that changes them, or a sandbox
# that stops asking the module at all, fails here by name instead of
# turning another suite quietly green.
#
# What pam_unix makes of 'U6aMy0wojraho', the crypt() of the empty string,
# changed between libpam 1.5 and 1.7 (helpers.bash has how), so those two
# facts are pinned for the libpam an appliance runs and skipped, by name,
# on any other.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    scratch_image
    NO_NULLOK=$IMAGE/etc/pam.d/no-nullok
    printf 'auth\trequired\tpam_unix.so\n' > "$NO_NULLOK"
    HASH=$(perl -e 'print crypt($ARGV[0], $ARGV[1])' s3cret '$6$keelpins$')
}

set_field() {
    printf 'root:%s:20718:0:99999:7:::\n' "$1" > "$SHADOW_FILE"
}

@test "the sandbox asks the module: a set password gets in and a wrong one does not" {
    set_field "$HASH"
    run authenticates s3cret
    [ "$status" -eq 0 ]
    [[ "$output" == *"prompted=yes"* ]]
    run refuses wrong
    [ "$status" -eq 0 ]
}

@test "a user the module cannot find is not read as a refusal" {
    run pam_verdict anything nobody-here
    [ "$status" -ge 3 ]
    run refuses anything nobody-here
    [ "$status" -ne 0 ]
}

@test "with nullok, an empty field lets any password in without asking" {
    set_field ''
    run pam_verdict "anything at all"
    [ "$status" -eq 0 ]
    [[ "$output" == *"prompted=no"* ]]
}

@test "without nullok, an empty field refuses every password" {
    set_field ''
    run nothing_authenticates root "$NO_NULLOK"
    [ "$status" -eq 0 ]
}

@test "libpam 1.7, with nullok: the crypt of the empty string lets any password in without asking" {
    require_measured_libpam
    set_field 'U6aMy0wojraho'
    run pam_verdict "anything at all"
    [ "$status" -eq 0 ]
    [[ "$output" == *"prompted=no"* ]]
}

@test "libpam 1.7, without nullok: the crypt of the empty string refuses every password" {
    require_measured_libpam
    set_field 'U6aMy0wojraho'
    run nothing_authenticates root "$NO_NULLOK"
    [ "$status" -eq 0 ]
}

@test "a field starting with '*' or '!' refuses everything, whatever the option" {
    local field stack
    for field in '*' '!' "!$HASH" "*$HASH"; do
        set_field "$field"
        for stack in "$PAM_WEBMIN" "$NO_NULLOK"; do
            run nothing_authenticates root "$stack"
            [ "$status" -eq 0 ]
            run refuses s3cret root "$stack"
            [ "$status" -eq 0 ]
        done
    done
}
