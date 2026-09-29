#!/usr/bin/env bats
# Tests for conf/turnkey.d/webmin-pam: what the PAM stack webmin uses lets
# through, before and after the script has run over it.
#
# tests/fixtures/pam.d-webmin is the file the webmin package installs, as
# it stands in a built core layer. The scratch image account has no password
# set on it, which is the case the option under test decides.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../conf/turnkey.d/webmin-pam"
    scratch_image
}

@test "a wrong password stops getting in" {
    run authenticates "anything at all"
    [ "$status" -eq 0 ]

    run "$SCRIPT"
    [ "$status" -eq 0 ]

    run refuses "anything at all"
    [ "$status" -eq 0 ]
}

@test "the empty password stops getting in as well, through this stack" {
    run authenticates ""
    [ "$status" -eq 0 ]

    run "$SCRIPT"
    [ "$status" -eq 0 ]

    run nothing_authenticates
    [ "$status" -eq 0 ]
}

@test "a stack that keeps the option still lets anything in, which is what the field is for" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]

    run authenticates "anything at all" root "$PAM_COMMON_AUTH"
    [ "$status" -eq 0 ]

    printf 'root:*:20718:0:99999:7:::\n' > "$SHADOW_FILE"
    run nothing_authenticates root "$PAM_COMMON_AUTH"
    [ "$status" -eq 0 ]
}

@test "the right password still gets in" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    echo 'root:hunter2' | chpasswd
    run authenticates "hunter2"
    [ "$status" -eq 0 ]
}

@test "the option goes whatever separates it from the module" {
    printf '#%%PAM-1.0\nauth required pam_unix.so nullok try_first_pass\n' \
        > "$PAM_WEBMIN"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run ! stack_allows_blank
    [ "$(sed -n '2p' "$PAM_WEBMIN")" = "auth required pam_unix.so try_first_pass" ]
}

@test "nothing else in the stack is touched" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    diff - "$PAM_WEBMIN" <<'EXPECTED'
#%PAM-1.0
auth	required	pam_unix.so
account	required	pam_unix.so
session	required	pam_unix.so
EXPECTED
}

@test "running it again changes nothing" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    first="$(cat "$PAM_WEBMIN")"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$PAM_WEBMIN")" = "$first" ]
}

@test "fails when the stack is not there" {
    rm "$PAM_WEBMIN"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$output" = "FATAL [webmin-pam]: $PAM_WEBMIN does not exist" ]
}

@test "fails rather than report success when the option survives" {
    printf '#%%PAM-1.0\nnullok\n' > "$PAM_WEBMIN"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$output" = "FATAL [webmin-pam]: nullok survived in $PAM_WEBMIN" ]
}
