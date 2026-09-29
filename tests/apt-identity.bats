#!/usr/bin/env bats
# Tests for the apt identity of an image:
#
#   overlays/turnkey.d/apt-identity/etc/apt/apt.conf.d/01keel   the User-Agent
#   conf/turnkey.d/apt-identity                                 keeps it the one in force
#   conf/bootstrap_apt                                          the source URIs
#
# Every User-Agent verdict is taken off the wire: a local server records the
# header a real apt-get update sent it, so what is asserted is what apt
# announces, not what the file says it should announce (docs/traps.md,
# "Asserting the configuration is not asserting the behaviour"). The source
# URIs are likewise read back from apt, which is asked what it would fetch
# from the stanzas conf/bootstrap_apt generates.
#
# Every refutation is written "run ! cmd", never a bare "! cmd": bash does not
# apply errexit to a negated command, so a bare one passes whatever happens
# and asserts nothing (measured; shellcheck SC2314 names it).

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO="$(cd "$TESTS_DIR/.." && pwd)"
    SCRIPT="$REPO/conf/turnkey.d/apt-identity"
    SHIPPED="$REPO/overlays/turnkey.d/apt-identity/etc/apt/apt.conf.d"
    BOOTSTRAP="$REPO/conf/bootstrap_apt"
    RECORDER="$TESTS_DIR/ua-recorder.py"

    # a scratch apt root: everything apt reads and writes is under here
    APTROOT="$BATS_TEST_TMPDIR/aptroot"
    export APT_CONF_DIR="$APTROOT/etc/apt/apt.conf.d"
    mkdir -p "$APT_CONF_DIR" "$APTROOT/etc/apt/sources.list.d" \
        "$APTROOT/var/lib/apt/lists/partial" \
        "$APTROOT/var/cache/apt/archives/partial" "$APTROOT/var/lib/dpkg"
    : > "$APTROOT/var/lib/dpkg/status"
    APT_CONFIG="$BATS_TEST_TMPDIR/apt.conf"
    export APT_CONFIG
    cat > "$APT_CONFIG" <<EOF
Dir "$APTROOT/";
Dir::State::status "$APTROOT/var/lib/dpkg/status";
EOF

    UA_LOG="$BATS_TEST_TMPDIR/ua.log"
    : > "$UA_LOG"
    RECORDER_PID=
}

teardown() {
    [ -n "${RECORDER_PID:-}" ] && kill "$RECORDER_PID" 2>/dev/null
    return 0
}

# the file the overlay ships, in the scratch tree
ship_01keel() {
    cp "$SHIPPED/01keel" "$APT_CONF_DIR/01keel"
}

# start_recorder [CERTFILE]; sets PORT
start_recorder() {
    local portfile="$BATS_TEST_TMPDIR/port"
    rm -f "$portfile"
    python3 "$RECORDER" "$UA_LOG" "$@" > "$portfile" &
    RECORDER_PID=$!
    local waited
    for waited in $(seq 1 100); do
        [ -s "$portfile" ] && break
        sleep 0.1
    done
    [ -n "$waited" ] || return 1
    [ -s "$portfile" ] || {
        echo "the recorder never printed a port" >&2
        return 1
    }
    PORT="$(cat "$portfile")"
}

# the distinct User-Agent strings the recorder was sent
sent_user_agents() {
    cut -f3 "$UA_LOG" | sort -u
}

# --------------------------------------------------- what apt puts on the wire

@test "apt announces Keel over http, and no appliance identity" {
    ship_01keel
    start_recorder
    printf 'deb [trusted=yes] http://127.0.0.1:%s/debian trixie main\n' "$PORT" \
        > "$APTROOT/etc/apt/sources.list"
    apt-get update >/dev/null 2>&1 || true

    [ -s "$UA_LOG" ]
    run sent_user_agents
    [ "$output" = "Keel APT-HTTP/1.3" ]
}

@test "apt announces the same over https" {
    ship_01keel
    openssl req -x509 -newkey rsa:2048 -days 1 -nodes -subj /CN=localhost \
        -keyout "$BATS_TEST_TMPDIR/key.pem" -out "$BATS_TEST_TMPDIR/cert.pem" 2>/dev/null
    cat "$BATS_TEST_TMPDIR/key.pem" "$BATS_TEST_TMPDIR/cert.pem" > "$BATS_TEST_TMPDIR/pair.pem"
    start_recorder "$BATS_TEST_TMPDIR/pair.pem"
    printf 'deb [trusted=yes] https://127.0.0.1:%s/debian trixie main\n' "$PORT" \
        > "$APTROOT/etc/apt/sources.list"
    apt-get update -o Acquire::https::Verify-Peer=false \
        -o Acquire::https::Verify-Host=false >/dev/null 2>&1 || true

    [ -s "$UA_LOG" ]
    run sent_user_agents
    [ "$output" = "Keel APT-HTTP/1.3" ]
}

@test "what apt announces names no appliance, no version and no codename" {
    ship_01keel
    start_recorder
    printf 'deb [trusted=yes] http://127.0.0.1:%s/debian trixie main\n' "$PORT" \
        > "$APTROOT/etc/apt/sources.list"
    apt-get update >/dev/null 2>&1 || true

    [ -s "$UA_LOG" ]
    local ua
    ua="$(sent_user_agents)"
    # the leak was everything inside the parentheses of the old header:
    # "TurnKey APT-HTTP/1.3 (turnkey-wordpress-19.0-trixie-amd64)"
    [[ "$ua" != *"("* ]]
    [[ "$ua" != *TurnKey* ]]
    [[ "$ua" != *turnkey* ]]
    [[ "$ua" != *wordpress* ]]
    [[ "$ua" != *trixie* ]]
    [[ "$ua" != *amd64* ]]
    [[ "$ua" != *19.0* ]]
}

@test "a stale 01turnkey from a parent layer beats 01keel until it is removed" {
    ship_01keel
    # what an appliance layer built on a core layer from before the change has
    printf 'Acquire::http::User-Agent "TurnKey APT-HTTP/1.3 (turnkey-wordpress-19.0-trixie-amd64)";\n' \
        > "$APT_CONF_DIR/01turnkey"
    start_recorder
    printf 'deb [trusted=yes] http://127.0.0.1:%s/debian trixie main\n' "$PORT" \
        > "$APTROOT/etc/apt/sources.list"
    apt-get update >/dev/null 2>&1 || true
    run sent_user_agents
    [ "$output" = "TurnKey APT-HTTP/1.3 (turnkey-wordpress-19.0-trixie-amd64)" ]

    # the conf script is what stops that
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    : > "$UA_LOG"
    rm -rf "$APTROOT/var/lib/apt/lists"
    mkdir -p "$APTROOT/var/lib/apt/lists/partial"
    apt-get update >/dev/null 2>&1 || true
    run sent_user_agents
    [ "$output" = "Keel APT-HTTP/1.3" ]
}

# ---------------------------------------------------------------- the script

@test "the conf script is a no-op when only 01keel is there" {
    ship_01keel
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$APT_CONF_DIR/01keel" ]
    run ls "$APT_CONF_DIR"
    [ "$output" = 01keel ]
}

@test "the conf script refuses when the overlay file is missing" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *01keel* ]]
}

@test "the conf script refuses when there is no apt configuration directory" {
    rm -rf "$APT_CONF_DIR"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *apt.conf.d* ]]
}

# ------------------------------------------- the URIs the bootstrap generates

# the body of the heredoc conf/bootstrap_apt writes to the named source file
stanza() {
    sed -n "/^ *cat > \$SOURCES_LIST\/$1 <<EOF\$/,/^EOF\$/p" "$BOOTSTRAP" \
        | sed '1d;$d'
}

# that body with the build's variables filled in, which is byte for byte what
# the bootstrap puts in the image.
#
# Every local below is read by the heredoc the eval expands, which is the
# build's own text, so shellcheck cannot see the use.
# shellcheck disable=SC2034
render() {
    local body
    body="$(stanza "$1")"
    [ -n "$body" ] || {
        echo "no heredoc for '$1' in $BOOTSTRAP" >&2
        return 1
    }
    local KEY_CODENAME=trixie CODENAME=trixie
    local MIRROR_URL=http://deb.debian.org/debian
    local SEC_MIRROR=http://security.debian.org/debian-security
    local sec_repo=trixie-security
    local tkl_apt_repo_enabled=yes tkl_apt_testing_enabled=yes
    local debian_backports_enabled=yes
    local SUPPORTED_ARCH=(amd64 arm64)
    local debian_components=(main non-free-firmware)
    eval "cat <<EOF
$body
EOF"
}

# every URI apt would fetch from the sources in the scratch tree, no network
fetch_uris() {
    apt-get indextargets --no-release-info --format '$(URI)' | sort -u
}

write_all_sources() {
    local f
    for f in sources.sources security.sources.sources turnkey-testing.sources \
             debian-backports.sources; do
        render "$f" > "$APTROOT/etc/apt/sources.list.d/$f"
    done
}

@test "no source the bootstrap writes fetches the turnkey archive over plain http" {
    write_all_sources
    fetch_uris > "$BATS_TEST_TMPDIR/uris"
    [ -s "$BATS_TEST_TMPDIR/uris" ]
    run ! grep -q '^http://archive\.turnkeylinux\.org' "$BATS_TEST_TMPDIR/uris"
}

@test "the turnkey archive is fetched over https, in all three suites" {
    write_all_sources
    run fetch_uris
    [ "$status" -eq 0 ]
    local suite
    for suite in trixie trixie-security trixie-testing; do
        grep -q "^https://archive\.turnkeylinux\.org/debian/dists/$suite/" <<< "$output"
    done
}

@test "the debian sources are left as Debian ships them" {
    write_all_sources
    run fetch_uris
    [ "$status" -eq 0 ]
    grep -q '^http://deb\.debian\.org/debian/dists/trixie/' <<< "$output"
    grep -q '^http://security\.debian\.org/debian-security/dists/trixie-security/' <<< "$output"
    grep -q '^http://deb\.debian\.org/debian/dists/trixie-backports/' <<< "$output"
}

@test "the legacy sources.list the bootstrap writes for older releases is https too" {
    # the pre deb822 branch of conf/bootstrap_apt, still reached for bookworm
    grep -n 'deb .*archive\.turnkeylinux\.org' "$BOOTSTRAP" > "$BATS_TEST_TMPDIR/legacy"
    [ -s "$BATS_TEST_TMPDIR/legacy" ]
    run ! grep -q 'http://archive\.turnkeylinux\.org' "$BATS_TEST_TMPDIR/legacy"
}
