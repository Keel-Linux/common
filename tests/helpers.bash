# Shared helpers for the conf scripts that decide whether an account of a
# freshly built image can be authenticated.
#
# The verdict these tests take is the one pam_unix takes, and it is taken
# the way pam_unix takes it:
#
#   crypt() is the real one, reached through perl. It is the function
#   pam_unix compares a submitted password with.
#
#   Around it, two rules out of Linux-PAM. _unix_blankpasswd() answers that
#   an account has no password when its stored field is empty or when
#   crypt() returns that field for the empty string, and it answers so only
#   while nullok is in effect; _unix_verify_password() then either accepts
#   without looking at what was submitted, or compares. The rules were
#   confirmed against the real helper, which is the code pam_unix runs:
#
#     printf '%s' "$password" | /usr/sbin/unix_chkpwd root nullok|nonull
#
#   with the stored field bind mounted over /etc/shadow under
#   'unshare -r -m'. Accepts and refusals both reproduced, for the fields
#   '', 'U6aMy0wojraho', '*' and '!'.
#
# The shadow tools are stubs, because usermod, chpasswd and passwd chroot
# into the root they are given and so cannot touch a scratch tree as an
# ordinary user. Each stub carries the behaviour it reproduces, and the
# command that measured it, at the top of the file.

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$HELPERS_DIR/fixtures"

# scratch_image
# The part of an image under construction that these scripts touch: the
# account databases, the PAM stack the webmin package installs and an empty
# systemd tree. Puts the stubs first on PATH and points every test hook at
# the scratch tree.
#
# root starts out carrying the field an earlier build wrote, so a script
# that writes nothing at all fails these tests instead of passing on the
# state it was handed.
scratch_image() {
    IMAGE=$BATS_TEST_TMPDIR/image
    mkdir -p "$IMAGE/etc/pam.d" "$IMAGE/etc/systemd/system"
    printf 'root:x:0:0:root:/root:/bin/bash\n' > "$IMAGE/etc/passwd"
    printf 'root:U6aMy0wojraho:20718:0:99999:7:::\n' > "$IMAGE/etc/shadow"
    cp "$FIXTURES/pam.d-webmin" "$IMAGE/etc/pam.d/webmin"

    export PATH="$HELPERS_DIR/stubs:$PATH"
    export STUB_LOG=$BATS_TEST_TMPDIR/calls.log
    : > "$STUB_LOG"

    export SHADOW_FILE=$IMAGE/etc/shadow
    export PAM_WEBMIN=$IMAGE/etc/pam.d/webmin
    export SYSTEMD_DIR=$IMAGE/etc/systemd/system
}

# crypt_of PASSWORD SETTING
# The real crypt(3). Prints what it returns, which is never the setting
# itself for a setting no hash can be built from.
crypt_of() {
    perl -e 'print crypt($ARGV[0], $ARGV[1]) // ""' "$1" "$2"
}

# field_of USER
# The password field USER carries in the scratch image.
field_of() {
    awk -F: -v user="${1:-root}" '$1 == user { print $2 }' "${SHADOW_FILE:?}"
}

# stack_allows_blank [PAM_FILE]
# Whether nullok is in effect for pam_unix on an auth line of the stack,
# which is what decides if a password that is not set authenticates.
stack_allows_blank() {
    grep -E '^[[:space:]]*auth[[:space:]]' "${1:-$PAM_WEBMIN}" \
        | grep -qE '\bnullok(_secure)?\b'
}

# blank_equivalent FIELD
# Linux-PAM's _unix_blankpasswd: a field that is empty, or that crypt()
# returns for the empty string, is an account whose password is not set.
blank_equivalent() {
    if [[ -z "$1" ]]; then
        return 0
    fi
    [[ "$(crypt_of "" "$1")" == "$1" ]]
}

# authenticates PASSWORD [USER] [PAM_FILE]
# Succeeds when pam_unix would let PASSWORD in for USER through that stack,
# fails when it would not.
authenticates() {
    local password=$1
    local user=${2:-root}
    local pam_file=${3:-$PAM_WEBMIN}
    local field
    field=$(field_of "$user")

    if stack_allows_blank "$pam_file" && blank_equivalent "$field"; then
        return 0
    fi
    if [[ -z "$field" ]]; then
        return 1
    fi
    [[ "$(crypt_of "$password" "$field")" == "$field" ]]
}

# nothing_authenticates [USER]
# Succeeds when no password at all gets USER in: the empty one, the ones
# worth trying first, and a right looking one.
nothing_authenticates() {
    local user=${1:-root}
    local password
    for password in "" " " "root" "toor" "password" "turnkey" "*" "!" \
            "U6aMy0wojraho" "hunter2"; do
        if authenticates "$password" "$user"; then
            echo "authenticated with '$password' against field '$(field_of "$user")'" >&2
            return 1
        fi
    done
}

# conditions_of UNIT_FILE
# The Condition lines of a unit file, as arguments for systemd-analyze.
conditions_of() {
    grep -E '^Condition' "$1"
}

# unit_would_start UNIT_FILE
# systemd's own verdict on whether a unit with those conditions would run,
# taken from systemd-analyze, not from reading the file.
unit_would_start() {
    local -a conditions
    readarray -t conditions < <(conditions_of "$1")
    [[ ${#conditions[@]} -gt 0 ]] || return 0
    systemd-analyze condition "${conditions[@]}" >/dev/null
}
