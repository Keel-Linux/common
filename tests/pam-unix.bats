#!/usr/bin/env bats
# What pam_unix itself does with the password fields and the option these
# conf scripts decide, asked of the real module (tests/pam-authenticate).
#
# These are not tests of this repository's scripts. They pin the facts the
# other suites rest on, so that a libpam that changes them, or a sandbox
# that stops asking the module at all, fails here by name instead of
# turning another suite quietly green.

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

@test "with nullok, a blank equivalent field lets any password in without asking" {
    local field
    for field in '' 'U6aMy0wojraho'; do
        set_field "$field"
        run pam_verdict "anything at all"
        [ "$status" -eq 0 ]
        [[ "$output" == *"prompted=no"* ]]
    done
}

@test "without nullok, the same fields refuse every password, the empty one included" {
    local field
    for field in '' 'U6aMy0wojraho'; do
        set_field "$field"
        run nothing_authenticates root "$NO_NULLOK"
        [ "$status" -eq 0 ]
    done
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
