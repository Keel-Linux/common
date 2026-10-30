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
    local KEEL_KEYRING=/usr/share/keyrings/keel-archive-keyring.asc
    local KEEL_SECURITY_KEYRING=/usr/share/keyrings/keel-security-keyring.asc
    local KEEL_TESTING_KEYRING=/usr/share/keyrings/keel-testing-keyring.asc
    local keel_testing_enabled="${KEEL_TESTING_ENABLED:-no}"
    eval "cat <<EOF
$body
EOF"
}

# what conf/bootstrap_apt decides from KEEL_APT_TRACK: the case block, run
# with the variable set as a build would set it, prints keel_testing_enabled
track_decision() {
    local block
    block="$(sed -n '/^case "\${KEEL_APT_TRACK:-stable}" in$/,/^esac$/p' "$BOOTSTRAP")"
    [ -n "$block" ] || { echo "no KEEL_APT_TRACK case in $BOOTSTRAP" >&2; return 1; }
    KEEL_APT_TRACK="$1" bash -c "fatal() { echo \"fatal: \$*\" >&2; exit 1; }
$block
echo \"\$keel_testing_enabled\""
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

@test "the bootstrap writes debian, security, backports and keel, and no TurnKey file" {
    run bootstrap_files
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'debian.sources\nsecurity.sources\ndebian-backports.sources\nkeel.sources')" ]
}

@test "the bootstrap gives the plan the Keel archive, stable on and testing off by default" {
    run render keel.sources
    [ "$status" -eq 0 ]
    [ "$(awk '/^URIs:/ { print $2 }' <<< "$output" | sort -u)" = https://archive.keellinux.org ]
    [ "$(awk '/^Suites:/ { print $2 }' <<< "$output" | tr '\n' ' ')" = "trixie trixie-testing " ]
    [ "$(awk '/^Enabled:/ { print $2 }' <<< "$output" | tr '\n' ' ')" = "yes no " ]
    # each track has the keyring of its role (decision 0055)
    [ "$(awk '/^Signed-By:/ { print $2 }' <<< "$output" | tr '\n' ' ')" = "/usr/share/keyrings/keel-archive-keyring.asc /usr/share/keyrings/keel-testing-keyring.asc " ]
    # the keys those files name are the ones mk/turnkey.mk copies in from keys/
    grep -q 'keys/keel-archive-keyring.asc \$O/bootstrap/usr/share/keyrings/keel-archive-keyring.asc' "$REPO/mk/turnkey.mk"
    grep -q 'keys/keel-testing-keyring.asc \$O/bootstrap/usr/share/keyrings/keel-testing-keyring.asc' "$REPO/mk/turnkey.mk"
    gpg --batch --quiet --show-keys --with-colons "$REPO/keys/keel-testing-keyring.asc" \
        | grep -q '^fpr:::::::::9B3CFC527FAD0EA5298D84ED05B5A6FE7E3BA58A:'
    [ "$(gpg --batch --quiet --show-keys --with-colons "$REPO/keys/keel-testing-keyring.asc" | grep -c '^pub:')" -eq 1 ]
    gpg --batch --quiet --show-keys --with-colons "$REPO/keys/keel-archive-keyring.asc" \
        | grep -q '^fpr:::::::::AD0964BE3F09DED469A3B6B2148E951314703180:'
    grep -q '^CONF_VARS += KEEL_APT_TRACK$' "$REPO/mk/turnkey.mk"
}

@test "KEEL_APT_TRACK picks the track: stable or unset keeps testing off, testing turns it on, anything else stops the build" {
    [ "$(track_decision "")" = no ]
    [ "$(track_decision stable)" = no ]
    [ "$(track_decision testing)" = yes ]
    run track_decision nightly
    [ "$status" -ne 0 ]
    [[ "$output" == *"KEEL_APT_TRACK must be 'stable' or 'testing', got 'nightly'"* ]]
    KEEL_TESTING_ENABLED=yes run render keel.sources
    [ "$(awk '/^Enabled:/ { print $2 }' <<< "$output" | tr '\n' ' ')" = "yes yes " ]
}

# the \$ in the patterns are grep's, not the shell's
# shellcheck disable=SC2016
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
    # The Keel security suite has a keyring of its own (decision 0055): the
    # bootstrap's armored copy here, the package's keyring after
    # conf/turnkey.d/keel-apt, tested below.
    ship_sources
    run awk '/^URIs:/ { u = $2 } /^Suites:/ { s = $2 } /^Signed-By:/ { print u, s, $2 }' "$SOURCES"/*.sources
    [ "$status" -eq 0 ]
    [ "$(wc -l <<< "$output")" -eq 6 ]
    local site suite keyring
    while read -r site suite keyring; do
        case "$site $suite" in
            *archive.keellinux.org*" trixie-security")
                [ "$keyring" = /usr/share/keyrings/keel-security-keyring.asc ] ;;
            *archive.keellinux.org*" trixie-testing")
                [ "$keyring" = /usr/share/keyrings/keel-testing-keyring.gpg ] ;;
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

@test "the base plan installs none of TurnKey's backup and DNS services, and no release meta package is built" {
    local name
    for name in tklbam hubdns webmin-tklbam turnkey-pypy2 py3curl-wrapper; do
        run ! grep -qE "^$name([[:space:]]|\$)" "$REPO/plans/turnkey/base"
    done
    run ! grep -q 'make-release-deb' "$REPO/mk/turnkey.mk"
    # the compatibility file is still written (decision 0014), by
    # bin/keel-version-files beside /etc/keel_version, from the version
    # turnkey-version.py derives; tests/mk-identity.bats makes the recipe
    # against stubs of fab and reads both files back
    grep -q 'release_version=.*turnkey-version.py' "$REPO/mk/turnkey.mk"
    # the $ are make's, matched literally
    # shellcheck disable=SC2016
    grep -q 'keel-version-files "\$\$release_version" \$O/root.patched' "$REPO/mk/turnkey.mk"
}

# ------------------------------------------------ the security-only upgrade

@test "security.sources alone, as the upgrade reads it, is Debian security and Keel security" {
    ship_sources
    run fetch_uris -o Dir::Etc::sourcelist="$SOURCES/security.sources" \
        -o Dir::Etc::sourceparts=/dev/null
    [ "$status" -eq 0 ]
    [ "$(sed -E 's|^([a-z]+://[^/]+/.*dists/[^/]+)/.*|\1|' <<< "$output" | sort -u)" = "$(printf 'http://security.debian.org/debian-security/dists/trixie-security\nhttps://archive.keellinux.org/dists/trixie-security')" ]
}

@test "the Keel stanza of security.sources is trixie-security, signed by the security key alone" {
    run render security.sources
    [ "$status" -eq 0 ]
    keel="$(awk 'BEGIN { RS = "" } /archive\.keellinux\.org/' <<< "$output")"
    [ "$(awk '/^Suites:/ { print $2 }' <<< "$keel")" = trixie-security ]
    [ "$(awk '/^Enabled:/ { print $2 }' <<< "$keel")" = yes ]
    [ "$(awk '/^Signed-By:/ { print $2 }' <<< "$keel")" = /usr/share/keyrings/keel-security-keyring.asc ]
    # the key that file names is the one mk/turnkey.mk copies in from keys/
    grep -q 'keys/keel-security-keyring.asc \$O/bootstrap/usr/share/keyrings/keel-security-keyring.asc' "$REPO/mk/turnkey.mk"
    gpg --batch --quiet --show-keys --with-colons "$REPO/keys/keel-security-keyring.asc" \
        | grep -q '^fpr:::::::::D97E853FBDBB24492002067BA92969F1BF3B71C6:'
    [ "$(gpg --batch --quiet --show-keys --with-colons "$REPO/keys/keel-security-keyring.asc" | grep -c '^pub:')" -eq 1 ]
}

@test "cron-apt's install actions read the security.sources the bootstrap writes" {
    local named
    named="$(sed -n '/5-install\.[a-z]* << EOF$/,/^EOF$/p' "$CRONAPT" | grep -o 'Dir::Etc::sourcelist=[^ ]*' | sort -u)"
    [ "$named" = "Dir::Etc::sourcelist=/etc/apt/sources.list.d/security.sources" ]
    [ "$(grep -c 'Dir::Etc::sourcelist=/etc/apt/sources.list.d/security.sources' "$CRONAPT")" -eq 2 ]
    bootstrap_files | grep -qx security.sources
    run ! grep -q 'security\.sources\.sources' "$CRONAPT"
}

# cronapt_actions: conf/turnkey.d/cronapt run on a scratch /etc/cron-apt;
# prints that directory
cronapt_actions() {
    local dir="$BATS_TEST_TMPDIR/cron-apt"
    mkdir -p "$dir/action.d"
    : > "$dir/config"
    sed "s|/etc/cron-apt|$dir|g" "$CRONAPT" > "$BATS_TEST_TMPDIR/cronapt"
    bash "$BATS_TEST_TMPDIR/cronapt" >&2
    echo "$dir"
}

# action LINE: one cron-apt action line run as cron-apt runs it, on the
# scratch tree (the image's sources.list.d path pointed at the scratch one)
action() {
    # shellcheck disable=SC2086
    apt-get -s ${1//\/etc\/apt\/sources.list.d/$SOURCES}
}

@test "cron-apt's update fails when an index cannot be fetched, so the run is logged and stops" {
    local dir
    dir="$(cronapt_actions)"
    [ "$(cat "$dir/action.d/0-update")" = "update -o quiet=2 --error-on=any" ]
    printf 'Types: deb\nURIs: http://[::1]:9/debian\nSuites: trixie-security\nComponents: main\nTrusted: yes\n' \
        > "$SOURCES/security.sources"
    # what cron-apt ran before: apt says it failed and exits 0 anyway
    run apt-get update -o quiet=2
    [ "$status" -eq 0 ]
    run apt-get $(cat "$dir/action.d/0-update")
    [ "$status" -ne 0 ]
}

@test "cron-apt's tzdata action upgrades tzdata from trixie-updates and nothing else" {
    local dir line
    dir="$(cronapt_actions)"
    make_archive debian Debian Debian trixie-updates tzdata=2026f-0 other=2.0-1
    apt-get update -qq 2>/dev/null
    installed tzdata=2026c-0 other=1.0-1
    line="$(tr -d '\\\n' < "$dir/action.d/6-tzdata")"
    run action "$line"
    [ "$status" -eq 0 ]
    grep -q '^Inst tzdata \[2026c-0\] (2026f-0 ' <<< "$output"
    run ! grep -q '^Inst other' <<< "$output"
}

@test "cron-apt's tzdata action installs nothing where tzdata is not installed" {
    local dir line
    dir="$(cronapt_actions)"
    make_archive debian Debian Debian trixie-updates tzdata=2026f-0
    apt-get update -qq 2>/dev/null
    line="$(tr -d '\\\n' < "$dir/action.d/6-tzdata")"
    run action "$line"
    [ "$status" -eq 0 ]
    run ! grep -q '^Inst' <<< "$output"
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

# dpkg-query and dpkg as the conf script sees them in the image: the
# installed packages are the lines of $PKGS ("name status version"). dpkg
# records its calls, and its purge of turnkey-keys removes what that package
# owns, as the real one does; --compare-versions is the real dpkg.
stub_dpkg() {
    PKGS="$BATS_TEST_TMPDIR/pkgs"
    : > "$PKGS"
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    cat > "$bin/dpkg-query" <<STUB
#!/bin/bash
name="\${@: -1}"
line="\$(awk -v n="\$name" '\$1 == n { print \$2, \$3 }' "$PKGS")"
[ -n "\$line" ] || { echo "dpkg-query: no packages found matching \$name" >&2; exit 1; }
echo "\$line"
STUB
    cat > "$bin/dpkg" <<STUB
#!/bin/bash
[ "\$1" = --compare-versions ] && exec /usr/bin/dpkg "\$@"
echo "\$*" >> "$BATS_TEST_TMPDIR/dpkg.calls"
if [ "\${@: -1}" = turnkey-keys ] && [[ " \$* " == *" -P "* ]]; then
    rm -f "$APTROOT"/usr/share/keyrings/tkl-*
    sed -i '/^turnkey-keys /d' "$PKGS"
fi
STUB
    chmod +x "$bin/dpkg-query" "$bin/dpkg"
    PATH="$bin:$PATH"
}

installed_pkg() {
    echo "$1 installed $2" >> "$PKGS"
}

conf_tree() {
    stub_dpkg
    ship_sources
    : > "$APTROOT/usr/share/keyrings/keel-archive-keyring.gpg"
    : > "$APTROOT/usr/share/keyrings/keel-security-keyring.gpg"
    : > "$APTROOT/usr/share/keyrings/keel-testing-keyring.gpg"
    installed_pkg keel-archive-keyring 0.3.0
}

run_conf() {
    APT_ROOT="$APTROOT" run "$KEEL_CONF"
}

@test "the conf script passes a tree with Keel's sources and keyring" {
    conf_tree
    run_conf
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/dpkg.calls" ]
}

@test "the conf script leaves the stable track alone by default and drops the bootstrap's key copy" {
    conf_tree
    echo "armored copy" > "$APTROOT/usr/share/keyrings/keel-archive-keyring.asc"
    local before
    before="$(cat "$SOURCES/keel.sources")"
    run_conf
    [ "$status" -eq 0 ]
    [ "$(cat "$SOURCES/keel.sources")" = "$before" ]
    [ "$(sed -n '/^Suites: trixie-testing$/,/^$/p' "$SOURCES/keel.sources" | awk '/^Enabled:/ { print $2 }')" = no ]
    [ ! -e "$APTROOT/usr/share/keyrings/keel-archive-keyring.asc" ]
    [ -f "$APTROOT/usr/share/keyrings/keel-archive-keyring.gpg" ]
}

@test "KEEL_APT_TRACK=testing makes the image follow the testing track, and changes nothing else" {
    conf_tree
    local before
    before="$(grep -v '^Enabled:' "$SOURCES/keel.sources")"
    KEEL_APT_TRACK=testing run_conf
    [ "$status" -eq 0 ]
    [ "$(grep -v '^Enabled:' "$SOURCES/keel.sources")" = "$before" ]
    [ "$(sed -n '/^Suites: trixie$/,/^$/p' "$SOURCES/keel.sources" | awk '/^Enabled:/ { print $2 }')" = yes ]
    [ "$(sed -n '/^Suites: trixie-testing$/,/^$/p' "$SOURCES/keel.sources" | awk '/^Enabled:/ { print $2 }')" = yes ]
    run fetch_uris
    grep -q '^https://archive\.keellinux\.org/dists/trixie-testing/main/' <<< "$output"
    grep -q '^https://archive\.keellinux\.org/dists/trixie/main/' <<< "$output"
}

@test "the conf script refuses an unknown KEEL_APT_TRACK, and testing without a stanza to enable" {
    conf_tree
    KEEL_APT_TRACK=nightly run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"KEEL_APT_TRACK must be 'stable' or 'testing', got 'nightly'"* ]]
    conf_tree
    sed -i '/^Suites: trixie-testing$/,/^$/d' "$SOURCES/keel.sources"
    KEEL_APT_TRACK=testing run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"no trixie-testing stanza to enable"* ]]
}

@test "the conf script refuses an image without the Keel keyring" {
    conf_tree
    rm "$APTROOT/usr/share/keyrings/keel-archive-keyring.gpg"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *keel-archive-keyring* ]]
}

@test "the conf script refuses a keyring package older than 0.3.0" {
    # 0.1.0 carries the signing subkey that 0.1.1 ships revoked, and 0.3.0
    # is the first with the security keyring
    conf_tree
    for old in 0.1.0 0.2.0; do
        sed -i "s/^keel-archive-keyring installed .*/keel-archive-keyring installed $old/" "$PKGS"
        run_conf
        [ "$status" -eq 1 ]
        [[ "$output" == *"keel-archive-keyring $old is older than 0.3.0"* ]]
    done
}

@test "the conf script points the Keel security stanza at the package's keyring and drops the bootstrap's copy" {
    conf_tree
    echo "armored copy" > "$APTROOT/usr/share/keyrings/keel-security-keyring.asc"
    local before
    before="$(grep -v '^Signed-By: /usr/share/keyrings/keel-security' "$SOURCES/security.sources")"
    run_conf
    [ "$status" -eq 0 ]
    [ "$(grep -v '^Signed-By: /usr/share/keyrings/keel-security' "$SOURCES/security.sources")" = "$before" ]
    grep -qx 'Signed-By: /usr/share/keyrings/keel-security-keyring.gpg' "$SOURCES/security.sources"
    run ! grep -q 'keel-security-keyring\.asc' "$SOURCES/security.sources"
    [ ! -e "$APTROOT/usr/share/keyrings/keel-security-keyring.asc" ]
}

@test "the conf script refuses an image without the security keyring" {
    conf_tree
    rm "$APTROOT/usr/share/keyrings/keel-security-keyring.gpg"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-security-keyring.gpg' is missing"* ]]
}

@test "the conf script refuses an image without security.sources" {
    conf_tree
    rm "$SOURCES/security.sources"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"security.sources' is missing"* ]]
}

@test "the conf script refuses a security.sources without the Keel security stanza, or with it disabled" {
    conf_tree
    awk 'BEGIN { RS = ""; ORS = "\n\n" } !/archive\.keellinux\.org/' "$SOURCES/security.sources" > "$SOURCES/s.new"
    mv "$SOURCES/s.new" "$SOURCES/security.sources"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"no enabled https://archive.keellinux.org trixie-security stanza"* ]]
    conf_tree
    sed -i '/^Suites: trixie-security$/,/^$/ s/^Enabled: yes$/Enabled: no/' "$SOURCES/security.sources"
    sed -i '/^URIs: https:\/\/archive/,/^$/ s/^Enabled: yes$/Enabled: no/' "$SOURCES/security.sources"
    run_conf
    [ "$status" -eq 1 ]
}

@test "the conf script refuses a keyring file no package installed" {
    conf_tree
    : > "$PKGS"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-archive-keyring is not installed"* ]]
}

@test "the conf script refuses an image without keel.sources" {
    conf_tree
    rm "$SOURCES/keel.sources"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *keel.sources* ]]
}

@test "the conf script refuses a keel.sources whose stable track is not enabled" {
    # what seven appliance recipes ship in their overlay at the same path,
    # which wins over common's: apt.keellinux.org, Enabled: no
    conf_tree
    printf 'Types: deb\nURIs: https://apt.keellinux.org\nSuites: trixie\nComponents: main\nEnabled: no\nSigned-By: /usr/share/keyrings/keel-archive-keyring.gpg\n' \
        > "$SOURCES/keel.sources"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"no enabled https://archive.keellinux.org trixie stanza"* ]]
}

@test "the conf script purges turnkey-keys, never deleting its files by hand" {
    conf_tree
    installed_pkg turnkey-keys 0.1
    : > "$APTROOT/usr/share/keyrings/tkl-archive-keyring.gpg"
    : > "$APTROOT/usr/share/keyrings/tkl-trixie-main.asc"
    run_conf
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/dpkg.calls")" = "--root=$APTROOT -P turnkey-keys" ]
    [ ! -e "$APTROOT/usr/share/keyrings/tkl-trixie-main.asc" ]
}

@test "the conf script purges turnkey-keys left as config-files too" {
    conf_tree
    echo "turnkey-keys config-files 0.1" >> "$PKGS"
    run_conf
    [ "$status" -eq 0 ]
    grep -qx -- "--root=$APTROOT -P turnkey-keys" "$BATS_TEST_TMPDIR/dpkg.calls"
}

@test "the conf script refuses a TurnKey keyring no package owns" {
    conf_tree
    : > "$APTROOT/usr/share/keyrings/tkl-trixie-main.asc"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *tkl-trixie-main.asc* ]]
}

@test "the conf script removes TurnKey's source files a parent layer left" {
    conf_tree
    # what a layer built on a bootstrap from before this change inherits
    printf 'Types: deb\nURIs: https://archive.turnkeylinux.org/debian\n' \
        > "$SOURCES/sources.sources"
    cp "$SOURCES/sources.sources" "$SOURCES/security.sources.sources"
    cp "$SOURCES/sources.sources" "$SOURCES/turnkey-testing.sources"
    printf 'Package: *\nPin: release o=turnkeylinux\nPin-Priority: 999\n' \
        > "$APTROOT/etc/apt/preferences"
    run_conf
    [ "$status" -eq 0 ]
    [ ! -e "$SOURCES/sources.sources" ]
    [ ! -e "$SOURCES/security.sources.sources" ]
    [ ! -e "$SOURCES/turnkey-testing.sources" ]
    [ ! -e "$APTROOT/etc/apt/preferences" ]
    run fetch_hosts
    [ "$output" = "$(printf 'archive.keellinux.org\ndeb.debian.org\nsecurity.debian.org')" ]
}

@test "the conf script refuses any other source that names the TurnKey archive" {
    conf_tree
    printf 'deb https://archive.turnkeylinux.org/debian trixie main\n' \
        > "$SOURCES/recipe.list"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *recipe.list* ]]
}

@test "the conf script refuses a TurnKey source in /etc/apt/sources.list" {
    conf_tree
    printf 'deb http://archive.turnkeylinux.org/debian trixie main\n' \
        > "$APTROOT/etc/apt/sources.list"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"/etc/apt/sources.list"* ]]
}

@test "the conf script refuses a TurnKey key in trusted.gpg.d, by its user id" {
    # renamed, so only the key itself says whose it is
    conf_tree
    mkdir -p "$APTROOT/etc/apt/trusted.gpg.d"
    cp "$TESTS_DIR/fixtures/tkl-trixie-main.asc" "$APTROOT/etc/apt/trusted.gpg.d/vendor.asc"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *trusted.gpg.d/vendor.asc* ]]
}

@test "the conf script refuses a TurnKey key in the legacy trusted.gpg" {
    conf_tree
    gpg --dearmor < "$TESTS_DIR/fixtures/tkl-trixie-main.asc" > "$APTROOT/etc/apt/trusted.gpg"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"/etc/apt/trusted.gpg"* ]]
}

@test "the conf script accepts Debian's keys in trusted.gpg.d" {
    conf_tree
    mkdir -p "$APTROOT/etc/apt/trusted.gpg.d"
    local k
    for k in /usr/share/keyrings/debian-archive-trixie-*.pgp; do
        [ -e "$k" ] || skip "no Debian archive keys on this host"
        cp "$k" "$APTROOT/etc/apt/trusted.gpg.d/"
    done
    run_conf
    [ "$status" -eq 0 ]
}

@test "the conf script refuses a TurnKey pin in preferences.d" {
    conf_tree
    printf 'Package: *\nPin: release o=turnkeylinux\nPin-Priority: 999\n' \
        > "$APTROOT/etc/apt/preferences.d/turnkey"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *preferences.d/turnkey* ]]
}

@test "the conf script leaves an operator's own preferences file alone" {
    conf_tree
    printf 'Package: foo\nPin: release a=trixie-backports\nPin-Priority: 500\n' \
        > "$APTROOT/etc/apt/preferences"
    run_conf
    [ "$status" -eq 0 ]
    [ -e "$APTROOT/etc/apt/preferences" ]
}

# ------------------------------------------------- the Keel pin must be 990

@test "the conf script refuses a Keel pin at 1001, as recipe overlays shipped" {
    conf_tree
    printf 'Package: *\nPin: release o=Keel Linux\nPin-Priority: 1001\n' \
        > "$APTROOT/etc/apt/preferences.d/keel"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"preferences.d/keel"* ]]
    [[ "$output" == *1001* ]]
}

@test "the conf script refuses an image with no Keel pin" {
    conf_tree
    rm "$APTROOT/etc/apt/preferences.d/keel"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"no pin on o=Keel Linux"* ]]
}

@test "the conf script refuses a second Keel pin at another priority anywhere" {
    conf_tree
    printf 'Package: *\nPin: release o=Keel Linux\nPin-Priority: 1001\n' \
        > "$APTROOT/etc/apt/preferences"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"/etc/apt/preferences"* ]]
}

@test "the conf script refuses a Keel pin without a priority line" {
    conf_tree
    printf 'Package: *\nPin: release o=Keel Linux\n' > "$APTROOT/etc/apt/preferences.d/keel"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"preferences.d/keel"* ]]
}

@test "the conf script leaves the build's pool pin, o=Keel Linux Pool at 1001, to the removelist" {
    # the captured pool a pinned build reads (decision 0012): its pin is the
    # pool's, removed by removelists-final/turnkey before the image is packed
    conf_tree
    printf 'Package: *\nPin: release o=Keel Linux Pool\nPin-Priority: 1001\n' \
        > "$APTROOT/etc/apt/preferences.d/keel-pool"
    run_conf
    [ "$status" -eq 0 ]
}

@test "the final removelist takes out every build time apt file, the staging pin included" {
    # the recipes pin the staging archive at 1001 for the build only
    # (preferences.d/keel-staging); the removelist is what holds whether or
    # not a recipe remembers to remove it
    local list="$REPO/removelists-final/turnkey" path
    for path in /etc/apt/sources.list.d/keel-staging.list \
        /etc/apt/preferences.d/keel-staging \
        /etc/apt/keyrings/keel-staging-keyring.asc /srv/keel-apt \
        /etc/apt/sources.list.d/keel-pool.sources /etc/apt/preferences.d/keel-pool; do
        grep -qxF "~$path" "$list"
    done
}

# ------------------------------------- the testing track, its own keyring

@test "the testing track of the shipped keel.sources names the testing keyring alone" {
    ship_sources
    testing="$(awk 'BEGIN { RS = "" } /(^|\n)Suites: trixie-testing(\n|$)/' "$SOURCES/keel.sources")"
    [ "$(awk '/^Signed-By:/ { print $2 }' <<< "$testing")" = /usr/share/keyrings/keel-testing-keyring.gpg ]
    [ "$(awk '/^Enabled:/ { print $2 }' <<< "$testing")" = no ]
    stable="$(awk 'BEGIN { RS = "" } /(^|\n)Suites: trixie(\n|$)/' "$SOURCES/keel.sources")"
    [ "$(awk '/^Signed-By:/ { print $2 }' <<< "$stable")" = /usr/share/keyrings/keel-archive-keyring.gpg ]
}

@test "the conf script refuses an image without the testing keyring" {
    conf_tree
    rm "$APTROOT/usr/share/keyrings/keel-testing-keyring.gpg"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-testing-keyring.gpg' is missing"* ]]
}

@test "the conf script drops the bootstrap's copy of the testing key" {
    conf_tree
    echo "armored copy" > "$APTROOT/usr/share/keyrings/keel-testing-keyring.asc"
    run_conf
    [ "$status" -eq 0 ]
    [ ! -e "$APTROOT/usr/share/keyrings/keel-testing-keyring.asc" ]
    [ -f "$APTROOT/usr/share/keyrings/keel-testing-keyring.gpg" ]
}

@test "KEEL_APT_TRACK=testing refuses a testing stanza that names another keyring" {
    conf_tree
    sed -i '/^Suites: trixie-testing$/,/^$/ s|^Signed-By: .*|Signed-By: /usr/share/keyrings/keel-archive-keyring.gpg|' "$SOURCES/keel.sources"
    KEEL_APT_TRACK=testing run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"trixie-testing stanza must name /usr/share/keyrings/keel-testing-keyring.gpg"* ]]
}
