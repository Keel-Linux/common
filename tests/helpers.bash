# Shared helpers for the conf scripts that decide whether an account of a
# freshly built image can be authenticated.
#
# The verdict these tests take is the one pam_unix takes, because it is
# pam_unix that takes it: tests/pam-authenticate loads the real libpam,
# starts the scratch image's own stack and calls pam_authenticate, in a user
# and mount namespace where the scratch shadow and passwd files are bind
# mounted over /etc/shadow and /etc/passwd. pam_unix runs in that process as
# root of the namespace, which is the path Webmin's miniserv takes: it reads
# the shadow file itself and does not go through unix_chkpwd.
#
# That matters, because the two paths disagree. Measured on libpam 1.7.0-5
# with a blank equivalent field ('' or 'U6aMy0wojraho', which crypt()
# returns for the empty string) and nullok in the stack, pam_unix in process
# accepts any password without asking for one, while unix_chkpwd refuses a
# non-empty one. An earlier version of these helpers modelled pam_unix by
# hand and reported acceptances the module does not make; nothing here is a
# model any more.
#
# The shadow tools are stubs, because usermod, chpasswd and passwd chroot
# into the root they are given and so cannot touch a scratch tree as an
# ordinary user. Each stub carries the behaviour it reproduces, and the
# command that measured it, at the top of the file.

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$HELPERS_DIR/fixtures"

# scratch_image
# The part of an image under construction that these scripts touch: the
# account databases, the PAM stack the webmin package installs, Debian's
# common-auth as a built core carries it, and an empty systemd tree. Puts the stubs first on PATH and points every test hook at
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
    cp "$FIXTURES/pam.d-common-auth" "$IMAGE/etc/pam.d/common-auth"

    export PATH="$HELPERS_DIR/stubs:$PATH"
    export STUB_LOG=$BATS_TEST_TMPDIR/calls.log
    : > "$STUB_LOG"

    export SHADOW_FILE=$IMAGE/etc/shadow
    export PAM_WEBMIN=$IMAGE/etc/pam.d/webmin
    export PAM_COMMON_AUTH=$IMAGE/etc/pam.d/common-auth
    export SYSTEMD_DIR=$IMAGE/etc/systemd/system
}

# field_of USER
# The password field USER carries in the scratch image.
field_of() {
    awk -F: -v user="${1:-root}" '$1 == user { print $2 }' "${SHADOW_FILE:?}"
}

# stack_allows_blank [PAM_FILE]
# Whether nullok is written on an auth line of the stack. Configuration,
# not behaviour: what it does is for pam_verdict to say.
stack_allows_blank() {
    grep -E '^[[:space:]]*auth[[:space:]]' "${1:-$PAM_WEBMIN}" \
        | grep -qE '\bnullok(_secure)?\b'
}

# pam_verdict PASSWORD [USER] [PAM_FILE]
# The real pam_authenticate over PAM_FILE (the scratch image's webmin stack
# by default) for USER with PASSWORD, against the scratch image's accounts.
# Returns 0 authenticated, 1 refused, and 3 or more when the question could
# not be asked.
#
# The verdict is read from the return code pam-authenticate prints, never
# from an exit status: unshare and mount exit 1 when they fail, and a
# sandbox that does not work must not be read as a refusal.
pam_verdict() {
    local password=$1
    local user=${2:-root}
    local pam_file=${3:-$PAM_WEBMIN}
    local output
    output=$(unshare --user --map-root-user --mount -- /bin/bash -c '
        mount --bind "$1" /etc/shadow || exit 4
        mount --bind "$2" /etc/passwd || exit 4
        exec "$3" "$4" "$5" "$6" "$7"
    ' pam_verdict "${SHADOW_FILE:?}" "$IMAGE/etc/passwd" \
        "$HELPERS_DIR/pam-authenticate" \
        "$(dirname "$pam_file")" "$(basename "$pam_file")" \
        "$user" "$password")
    echo "$output"
    case $output in
        "pam=0 "*) return 0 ;;
        "pam=7 "*) return 1 ;;
        "pam="*)   return 3 ;;
        *)         echo "pam_verdict: the sandbox did not answer" >&2
                   return 4 ;;
    esac
}

# authenticates PASSWORD [USER] [PAM_FILE]
# Succeeds when pam_unix lets PASSWORD in, fails otherwise, including when
# the question could not be asked.
authenticates() {
    local rc=0
    pam_verdict "$@" || rc=$?
    [[ $rc -eq 0 ]]
}

# refuses PASSWORD [USER] [PAM_FILE]
# Succeeds only when pam_unix refuses PASSWORD. A refutation is written with
# this and never as '! authenticates', which a sandbox that does not work
# would satisfy.
refuses() {
    local rc=0
    pam_verdict "$@" || rc=$?
    if [[ $rc -gt 1 ]]; then
        echo "pam_verdict could not ask (status $rc)" >&2
    fi
    [[ $rc -eq 1 ]]
}

# nothing_authenticates [USER] [PAM_FILE]
# Succeeds when pam_unix refuses every password tried: the empty one, the
# ones worth trying first, and a right looking one.
nothing_authenticates() {
    local user=${1:-root}
    local pam_file=${2:-$PAM_WEBMIN}
    local password
    for password in "" " " "root" "toor" "password" "turnkey" "*" "!" \
            "U6aMy0wojraho" "hunter2"; do
        if ! refuses "$password" "$user" "$pam_file"; then
            echo "not refused: '$password' against field '$(field_of "$user")'" >&2
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
