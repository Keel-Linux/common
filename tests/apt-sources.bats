#!/usr/bin/env bats
# Tests for the package sources a Keel image ships (handbook decisions 0016,
# 0039 and 0043, tracker#23):
#
#   conf/bootstrap_apt                       Debian's sources: debian.sources,
#                                            security.sources, debian-backports
#   overlays/turnkey.d/keel-apt              the Keel archive and its pin
#   conf/turnkey.d/keel-apt                  refuses an image whose sources
#                                            name the TurnKey archive or whose
#                                            Keel keyring is missing
#   conf/turnkey.d/cronapt                   the security-only cron-apt action
#   plans/turnkey/base                       the keyring package
#
# Every verdict about what apt fetches or installs is taken from apt itself:
# it is asked which index files it would fetch, and which version it would
# install, from local archives with the Origin the real ones carry.
#
# Every refutation is written "run ! cmd", never a bare "! cmd" (SC2314).

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO="$(cd "$TESTS_DIR/.." && pwd)"
    BOOTSTRAP="$REPO/conf/bootstrap_apt"
    KEEL_OVERLAY="$REPO/overlays/turnkey.d/keel-apt"
    KEEL_CONF="$REPO/conf/turnkey.d/keel-apt"
    CRONAPT="$REPO/conf/turnkey.d/cronapt"

    APTROOT="$BATS_TEST_TMPDIR/aptroot"
    SOURCES="$APTROOT/etc/apt/sources.list.d"
    mkdir -p "$SOURCES" "$APTROOT/etc/apt/preferences.d" \
        "$APTROOT/etc/apt/apt.conf.d" \
        "$APTROOT/var/lib/apt/lists/partial" \
        "$APTROOT/var/cache/apt/archives/partial" "$APTROOT/var/lib/dpkg" \
        "$APTROOT/usr/share/keyrings"
    : > "$APTROOT/var/lib/dpkg/status"
    APT_CONFIG="$BATS_TEST_TMPDIR/apt.conf"
    export APT_CONFIG
    cat > "$APT_CONFIG" <<EOF
Dir "$APTROOT/";
Dir::State::status "$APTROOT/var/lib/dpkg/status";
Dir::Etc::preferences "$APTROOT/etc/apt/preferences";
Dir::Etc::preferencesparts "$APTROOT/etc/apt/preferences.d";
APT::Architecture "amd64";
APT::Architectures { "amd64"; };
EOF
}

# ------------------------------------------------------------------ helpers

# the body of the heredoc conf/bootstrap_apt writes to the named source file
stanza() {
    sed -n "/^ *cat > \$SOURCES_LIST\/$1 <<EOF\$/,/^EOF\$/p" "$BOOTSTRAP" \
        | sed '1d;$d'
}

# that body with a trixie build's variables filled in, byte for byte what
# the bootstrap writes. The locals are read by the heredoc the eval expands.
# shellcheck disable=SC2034
render() {
    local body
    body="$(stanza "$1")"
    [ -n "$body" ] || {
        echo "no heredoc for '$1' in $BOOTSTRAP" >&2
        return 1
    }
    local CODENAME=trixie
    local MIRROR_URL=http://deb.debian.org/debian
    local SEC_MIRROR=http://security.debian.org/debian-security
    local sec_repo=trixie-security
    local debian_backports_enabled=no
    local debian_components=(main non-free-firmware)
    local DEBIAN_KEYRING=/usr/share/keyrings/debian-archive-keyring.pgp
    eval "cat <<EOF
$body
EOF"
}

# the names of the files conf/bootstrap_apt writes into sources.list.d,
# but Sury's PHP source, which it writes only for a recipe that sets
# PHP_VERSION. The \$ is sed's, not the shell's.
# shellcheck disable=SC2016
bootstrap_files() {
    sed -n 's|^ *cat > \$SOURCES_LIST/\([^ ]*\) <<EOF$|\1|p' "$BOOTSTRAP" \
        | grep -v '^php\.'
}

# what an image has in sources.list.d and preferences.d: the bootstrap's
# files and the overlay's
ship_sources() {
    local f
    while read -r f; do
        render "$f" > "$SOURCES/$f"
    done < <(bootstrap_files)
    cp -a "$KEEL_OVERLAY/etc/apt/." "$APTROOT/etc/apt/"
}

# every index URI apt would fetch from what is in the scratch tree; $(URI)
# is apt's format field
# shellcheck disable=SC2016
fetch_uris() {
    apt-get indextargets --no-release-info --format '$(URI)' "$@" | sort -u
}

# the hosts of those URIs
fetch_hosts() {
    fetch_uris "$@" | sed -E 's|^[a-z]+://([^/]+)/.*|\1|' | sort -u
}

# ------------------------------------------------- what the image fetches

@test "the bootstrap writes debian, security and backports, and no TurnKey file" {
    run bootstrap_files
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'debian.sources\nsecurity.sources\ndebian-backports.sources')" ]
}

@test "the bootstrap removes the files it used to write before writing its own" {
    # left beside debian.sources, sources.sources names the same Debian
    # archive with another Signed-By and apt refuses every source (measured
    # on the step8 image: "Conflicting values set for option Signed-By")
    local rm_line write_line
    rm_line="$(grep -n '^rm -f \$SOURCES_LIST/sources.sources \$SOURCES_LIST/security.sources.sources \$SOURCES_LIST/turnkey-testing.sources$' "$BOOTSTRAP" | cut -d: -f1)"
    write_line="$(grep -n '^cat > \$SOURCES_LIST/debian.sources <<EOF$' "$BOOTSTRAP" | cut -d: -f1)"
    [ -n "$rm_line" ]
    [ -n "$write_line" ]
    [ "$rm_line" -lt "$write_line" ]
}

@test "an image fetches from Debian, Debian security and the Keel archive only" {
    ship_sources
    run fetch_hosts
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'archive.keellinux.org\ndeb.debian.org\nsecurity.debian.org')" ]
}

@test "Debian's suites are trixie, trixie-updates and trixie-security" {
    ship_sources
    run fetch_uris
    [ "$status" -eq 0 ]
    grep -q '^http://deb\.debian\.org/debian/dists/trixie/main/' <<< "$output"
    grep -q '^http://deb\.debian\.org/debian/dists/trixie-updates/main/' <<< "$output"
    grep -q '^http://security\.debian\.org/debian-security/dists/trixie-security/main/' <<< "$output"
    run ! grep -q 'trixie-backports' <<< "$output"
}

@test "Keel's packages come from the stable track, trixie, with testing off" {
    ship_sources
    run fetch_uris
    [ "$status" -eq 0 ]
    grep -q '^https://archive\.keellinux\.org/dists/trixie/main/' <<< "$output"
    run ! grep -q 'archive\.keellinux\.org/dists/trixie-testing/' <<< "$output"
    # the testing track is there for the operator to turn on
    grep -q '^Suites: trixie-testing$' "$SOURCES/keel.sources"
    sed -i 's/^Enabled: no$/Enabled: yes/' "$SOURCES/keel.sources"
    run fetch_uris
    grep -q '^https://archive\.keellinux\.org/dists/trixie-testing/main/' <<< "$output"
}

@test "each archive is trusted with its own keyring" {
    # apt does not report Signed-By, so the stanzas are read: URIs and
    # Signed-By of each, enabled or not
    ship_sources
    run awk '/^URIs:/ { u = $2 } /^Signed-By:/ { print u, $2 }' "$SOURCES"/*.sources
    [ "$status" -eq 0 ]
    [ "$(wc -l <<< "$output")" -eq 5 ]
    local site keyring
    while read -r site keyring; do
        case "$site" in
            *archive.keellinux.org*)
                [ "$keyring" = /usr/share/keyrings/keel-archive-keyring.gpg ] ;;
            *debian.org*)
                [ "$keyring" = /usr/share/keyrings/debian-archive-keyring.pgp ] ;;
            *) echo "unexpected site $site" >&2; return 1 ;;
        esac
    done <<< "$output"
}

@test "no source or keyring names TurnKey, enabled or disabled" {
    ship_sources
    run ! grep -rniE 'turnkeylinux|tkl-' "$APTROOT/etc/apt"
    run ! grep -niE 'turnkeylinux\.org/debian|tkl-.*keyring|tkl-archive' "$BOOTSTRAP"
    [ -z "$(find "$REPO/overlays/bootstrap_apt" -name 'tkl-*')" ]
    [ ! -e "$REPO/overlays/bootstrap_apt/etc/apt/preferences" ]
}

@test "the base plan installs the Keel keyring package, not turnkey-keys" {
    grep -qE '^keel-archive-keyring([[:space:]]|$)' "$REPO/plans/turnkey/base"
    run ! grep -qE '^turnkey-keys' "$REPO/plans/turnkey/base"
}

# ------------------------------------------------ the security-only upgrade

@test "security.sources alone, as the upgrade reads it, is Debian security only" {
    ship_sources
    run fetch_hosts -o Dir::Etc::sourcelist="$SOURCES/security.sources" \
        -o Dir::Etc::sourceparts=/dev/null
    [ "$status" -eq 0 ]
    [ "$output" = security.debian.org ]
}

@test "cron-apt's install actions read the security.sources the bootstrap writes" {
    local named
    named="$(grep -o 'Dir::Etc::sourcelist=[^ ]*' "$CRONAPT" | sort -u)"
    [ "$named" = "Dir::Etc::sourcelist=/etc/apt/sources.list.d/security.sources" ]
    [ "$(grep -c 'Dir::Etc::sourcelist=' "$CRONAPT")" -eq 2 ]
    bootstrap_files | grep -qx security.sources
    run ! grep -q 'security\.sources\.sources' "$CRONAPT"
}

# ----------------------------------------------------------- the pin, live

# make_archive NAME ORIGIN LABEL SUITE PKG=VER...: a local archive whose
# Release carries the Origin and Label given, as the real ones do
make_archive() {
    local name="$1" origin="$2" label="$3" suite="$4" spec dir pkg ver
    shift 4
    dir="$BATS_TEST_TMPDIR/archives/$name"
    mkdir -p "$dir/dists/$suite/main/binary-amd64"
    : > "$dir/dists/$suite/main/binary-amd64/Packages"
    for spec in "$@"; do
        pkg="${spec%%=*}" ver="${spec#*=}"
        cat >> "$dir/dists/$suite/main/binary-amd64/Packages" <<EOF
Package: $pkg
Version: $ver
Architecture: amd64
Maintainer: test <test@example.org>
Filename: pool/${pkg}_${ver}_amd64.deb
Size: 1
SHA256: 0000000000000000000000000000000000000000000000000000000000000000
Description: $pkg

EOF
    done
    (cd "$dir/dists/$suite" && apt-ftparchive \
        -o APT::FTPArchive::Release::Origin="$origin" \
        -o APT::FTPArchive::Release::Label="$label" \
        -o APT::FTPArchive::Release::Suite="$suite" \
        -o APT::FTPArchive::Release::Codename="$suite" \
        release . > Release)
    printf 'Types: deb\nURIs: file:%s\nSuites: %s\nComponents: main\nTrusted: yes\n' \
        "$dir" "$suite" > "$SOURCES/$name.sources"
}

# installed PKG=VER...: dpkg status entries
installed() {
    local spec
    for spec in "$@"; do
        printf 'Package: %s\nStatus: install ok installed\nVersion: %s\nArchitecture: amd64\nMaintainer: t <t@example.org>\nDescription: x\n\n' \
            "${spec%%=*}" "${spec#*=}" >> "$APTROOT/var/lib/dpkg/status"
    done
}

candidate() {
    apt-cache policy "$1" | sed -n 's/^ *Candidate: //p'
}

pin_setup() {
    cp -a "$KEEL_OVERLAY/etc/apt/preferences.d/." "$APTROOT/etc/apt/preferences.d/"
    make_archive debian Debian Debian trixie \
        rebuilt=1.2-1 plain=3.0-1 ahead=2.0-1
    make_archive keel "Keel Linux" "Keel Linux" trixie \
        rebuilt=1.1-1+keel1 ahead=2.0+keel5 ours=0.3.5
    apt-get update -qq 2>/dev/null
}

@test "the pin is on the Origin of the Keel archive, at 990" {
    local pin="$KEEL_OVERLAY/etc/apt/preferences.d/keel"
    grep -qx 'Package: \*' "$pin"
    grep -qx 'Pin: release o=Keel Linux' "$pin"
    grep -qx 'Pin-Priority: 990' "$pin"
}

@test "a Keel package wins over a higher Debian version of the same name" {
    pin_setup
    installed rebuilt=1.0-1
    [ "$(candidate rebuilt)" = 1.1-1+keel1 ]
    [ "$(candidate plain)" = 3.0-1 ]
    [ "$(candidate ours)" = 0.3.5 ]
}

@test "a Keel rebuild is kept when Debian publishes a higher version" {
    pin_setup
    installed rebuilt=1.1-1+keel1
    [ "$(candidate rebuilt)" = 1.1-1+keel1 ]
    run apt-get -s upgrade
    run ! grep -q '^Inst rebuilt' <<< "$output"
}

@test "nothing newer than the Keel archive is downgraded (tracker#23)" {
    pin_setup
    # what a test build installs: newer than what the archive publishes
    installed ours=0.10.2 ahead=2.0+keel11
    [ "$(candidate ours)" = 0.10.2 ]
    [ "$(candidate ahead)" = 2.0+keel11 ]
    run apt-get -s upgrade
    [ "$status" -eq 0 ]
    run ! grep -qE '^Inst (ours|ahead) .*\[' <<< "$output"
    run apt-get -s dist-upgrade
    [ "$status" -eq 0 ]
    run ! grep -q 'DOWNGRADED' <<< "$output"
}

@test "a package only Debian carries is left to Debian's own policy" {
    pin_setup
    installed plain=2.0-1
    [ "$(candidate plain)" = 3.0-1 ]
    run apt-get -s upgrade
    grep -q '^Inst plain \[2\.0-1\] (3\.0-1 ' <<< "$output"
}

# ---------------------------------------------------- conf/turnkey.d/keel-apt

conf_tree() {
    ship_sources
    : > "$APTROOT/usr/share/keyrings/keel-archive-keyring.gpg"
}

@test "the conf script passes a tree with Keel's sources and keyring" {
    conf_tree
    APT_ROOT="$APTROOT" run "$KEEL_CONF"
    [ "$status" -eq 0 ]
}

@test "the conf script refuses an image without the Keel keyring" {
    conf_tree
    rm "$APTROOT/usr/share/keyrings/keel-archive-keyring.gpg"
    APT_ROOT="$APTROOT" run "$KEEL_CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *keel-archive-keyring* ]]
}

@test "the conf script refuses an image without keel.sources" {
    conf_tree
    rm "$SOURCES/keel.sources"
    APT_ROOT="$APTROOT" run "$KEEL_CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *keel.sources* ]]
}

@test "the conf script removes TurnKey's files a parent layer left" {
    conf_tree
    # what a layer built on a bootstrap from before this change inherits
    printf 'Types: deb\nURIs: https://archive.turnkeylinux.org/debian\n' \
        > "$SOURCES/sources.sources"
    cp "$SOURCES/sources.sources" "$SOURCES/security.sources.sources"
    cp "$SOURCES/sources.sources" "$SOURCES/turnkey-testing.sources"
    printf 'Package: *\nPin: release o=turnkeylinux\nPin-Priority: 999\n' \
        > "$APTROOT/etc/apt/preferences"
    : > "$APTROOT/usr/share/keyrings/tkl-archive-keyring.gpg"
    : > "$APTROOT/usr/share/keyrings/tkl-trixie-main.asc"
    APT_ROOT="$APTROOT" run "$KEEL_CONF"
    [ "$status" -eq 0 ]
    [ ! -e "$SOURCES/sources.sources" ]
    [ ! -e "$SOURCES/security.sources.sources" ]
    [ ! -e "$SOURCES/turnkey-testing.sources" ]
    [ ! -e "$APTROOT/etc/apt/preferences" ]
    [ ! -e "$APTROOT/usr/share/keyrings/tkl-trixie-main.asc" ]
    run fetch_hosts
    [ "$output" = "$(printf 'archive.keellinux.org\ndeb.debian.org\nsecurity.debian.org')" ]
}

@test "the conf script refuses any other source that names the TurnKey archive" {
    conf_tree
    printf 'deb https://archive.turnkeylinux.org/debian trixie main\n' \
        > "$SOURCES/recipe.list"
    APT_ROOT="$APTROOT" run "$KEEL_CONF"
    [ "$status" -eq 1 ]
    [[ "$output" == *recipe.list* ]]
}

@test "the conf script leaves an operator's own preferences file alone" {
    conf_tree
    printf 'Package: foo\nPin: release a=trixie-backports\nPin-Priority: 500\n' \
        > "$APTROOT/etc/apt/preferences"
    APT_ROOT="$APTROOT" run "$KEEL_CONF"
    [ "$status" -eq 0 ]
    [ -e "$APTROOT/etc/apt/preferences" ]
}
