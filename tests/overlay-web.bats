#!/usr/bin/env bats
# The Keel Web overlay packages of packages/ (nginx, coraza, anubis),
# installed on a Debian 13 machine with systemd running: Nginx answers
# /keel-health on the loopback only, Coraza and Anubis are installed and
# off, and each turns on and off as keel spec apply drives it (decision
# 0041, first implementation, step 6).
#
# This suite changes the machine it runs on: it installs and removes
# packages, starts and stops services and edits the rule set. It runs only
# where KEEL_OVERLAY_INSTALL_TEST=1 says the machine is disposable, as
# root, under systemd, after the three keel-overlay-* packages have been
# installed with their dependencies. OVERLAY_DEBS names the directory
# holding the overlay .deb files, libnginx-mod-http-coraza's and
# coreruleset's (default dist/ of the repository). The CI job "web" of
# packages.yml runs it in a trixie LXC system container booted with
# systemd; so does the test of the Core image.
#
# Every verdict is the one Nginx, curl, systemctl, dpkg and keel give on
# the machine. Refutations are written "run ! cmd", never a bare "! cmd".

bats_require_minimum_version 1.5.0

OVERLAYS=(nginx coraza anubis)
HEALTH="http://[::1]/keel-health"
PROBE="$HEALTH?keel-waf-probe=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
MODULE_LINK=/etc/nginx/modules-enabled/50-mod-http-coraza.conf
WAF_LINK=/etc/nginx/conf.d/keel-coraza.conf
STATE=/usr/lib/keel/overlays/coraza/state
KEPT_CORAZA=/var/lib/keel-overlay-coraza/kept-link
ANUBIS=anubis@keel.service
KEY=/etc/anubis/keel.key
RULES=/etc/coreruleset/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf
TEST_SITE=/etc/nginx/sites-enabled/zz-keel-anubis-test
SPEC=/etc/keel/instance.yaml
PRIMARY_KEY=/etc/keel/secrets/keel-test-anubis-key

setup_file() {
    if [ "${KEEL_OVERLAY_INSTALL_TEST:-}" != 1 ]; then
        echo "refusing to run: this suite installs and removes packages;" \
            "set KEEL_OVERLAY_INSTALL_TEST=1 on a disposable machine" >&2
        return 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo "refusing to run: needs root" >&2
        return 1
    fi
    if [ ! -d /run/systemd/system ]; then
        echo "refusing to run: needs systemd running; Nginx and Anubis" \
            "are its services" >&2
        return 1
    fi
}

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO="$(cd "$TESTS_DIR/.." && pwd)"
    DEBS="${OVERLAY_DEBS:-$REPO/dist}"
    export DEBIAN_FRONTEND=noninteractive
}

teardown() {
    if [ -d "$IMAGE_BUILD_HIDDEN" ] && [ ! -e /run/systemd/system ]; then
        mv "$IMAGE_BUILD_HIDDEN" /run/systemd/system
    fi
    if [ -f "$BATS_TEST_TMPDIR/rules" ]; then
        cp "$BATS_TEST_TMPDIR/rules" "$RULES"
    fi
    if [ -f "$BATS_TEST_TMPDIR/instance.yaml" ]; then
        cp -p "$BATS_TEST_TMPDIR/instance.yaml" "$SPEC"
    fi
    if [ -f "$BATS_TEST_TMPDIR/no-spec" ]; then
        rm -f "$SPEC"
    fi
    rm -f "$TEST_SITE" "$KEY.from-primary" "$PRIMARY_KEY"
    if [ "$(dpkg-query -W -f='${Version}' coreruleset)" != \
            "$(dpkg-deb -f "$(deb_of coreruleset)" Version)" ]; then
        dpkg -i "$(deb_of coreruleset)"
    fi
    if [ "$(dpkg-query -W -f='${db:Status-Status}' keel-overlay-coraza \
            2>/dev/null)" != installed ]; then
        dpkg -i "$(deb_of keel-overlay-coraza)"
    fi
    if [ "$(dpkg-query -W -f='${db:Status-Status}' keel-overlay-anubis \
            2>/dev/null)" != installed ]; then
        dpkg -i "$(deb_of keel-overlay-anubis)"
    fi
    # every test starts from the simple installation: Coraza and Anubis off
    rm -f "$MODULE_LINK" "$MODULE_LINK.removed" "$WAF_LINK"
    systemctl disable --now "$ANUBIS" >/dev/null 2>&1 || true
    systemctl reset-failed "$ANUBIS" keel-overlay-anubis-key.service \
        >/dev/null 2>&1 || true
    rm -f "$KEY"
    systemctl reload nginx.service
    answers 204 "$HEALTH"
}

deb_of() {
    local debs=("$DEBS/$1"_*.deb)
    [ -f "${debs[0]}" ] || {
        echo "no $1 package in $DEBS" >&2
        return 1
    }
    echo "${debs[0]}"
}

# a copy of DEB under VERSION, maintainer scripts and all, so installing it
# is a real upgrade (as tests/overlay-install.bats does)
with_version() {
    local deb="$1" version="$2" tree
    tree="$(mktemp -d "$BATS_TEST_TMPDIR/deb.XXXXXX")"
    dpkg-deb -R "$deb" "$tree/root"
    awk -v v="$version" '/^Version: / { $0 = "Version: " v } { print }' \
        "$tree/root/DEBIAN/control" > "$tree/control"
    mv "$tree/control" "$tree/root/DEBIAN/control"
    dpkg-deb -b "$tree/root" "$tree/upgraded.deb" >&2
    echo "$tree/upgraded.deb"
}

# as_image_build COMMAND...
# Runs COMMAND as an image build sees the machine: no /run/systemd/system.
# It is moved aside for the command and back, as tests/overlay-install.bats
# does: an unprivileged LXC container, the CI's, may not mount a tmpfs
# over it. teardown puts it back if a test dies in between.
IMAGE_BUILD_HIDDEN=/run/systemd/system.keel-image-build

as_image_build() {
    local rc=0
    mv /run/systemd/system "$IMAGE_BUILD_HIDDEN"
    "$@" || rc=$?
    mv "$IMAGE_BUILD_HIDDEN" /run/systemd/system
    return "$rc"
}

code() {
    curl --globoff --silent --output /dev/null --max-time 5 \
        --write-out '%{http_code}' "$@" || true
}

# answers CODE URL [CURL ARGS]: within ten seconds, as a reload settles
answers() {
    local want="$1" got try
    shift
    for try in $(seq 10); do
        got="$(code "$@")"
        [ "$got" = "$want" ] && return 0
        sleep 1
    done
    echo "${*: -1}: got $got, expected $want" >&2
    return 1
}

# the machine's own addresses that are not the loopback
own_addresses() {
    local address
    for address in $(hostname -I); do
        case "$address" in
            fe80:*) ;;
            *:*) echo "[$address]" ;;
            *) echo "$address" ;;
        esac
    done
}

workers_map() {
    local pid
    for pid in $(pgrep -f 'nginx: worker process'); do
        grep -qF "$1" "/proc/$pid/maps" && return 0
    done
    return 1
}

# the workers of before a reload finish their requests and exit on their
# own time: within ten seconds no worker maps the engine
no_worker_maps() {
    local try
    for try in $(seq 10); do
        workers_map "$1" || return 0
        sleep 1
    done
    echo "a worker still maps $1" >&2
    return 1
}

assert_coraza_off() {
    [ ! -L "$MODULE_LINK" ]
    [ ! -L "$WAF_LINK" ]
    no_worker_maps libcoraza.so
    answers 204 "$PROBE"
}

# ------------------------------------------------------------ the packages

@test "the three web overlay packages are installed" {
    local name
    for name in "${OVERLAYS[@]}"; do
        run dpkg-query -W -f='${db:Status-Status}' "keel-overlay-$name"
        [ "$output" = installed ]
    done
}

@test "each manifest is installed where docs/manifest-v1.md puts it, as its source says" {
    local name
    for name in "${OVERLAYS[@]}"; do
        cmp "$REPO/packages/$name/manifest.yaml" \
            "/usr/share/keel/overlays/$name.yaml"
        run dpkg-query -S "/usr/share/keel/overlays/$name.yaml"
        [ "$output" = "keel-overlay-$name: /usr/share/keel/overlays/$name.yaml" ]
    done
}

@test "keel manifest validate accepts each web overlay on this machine" {
    local name
    for name in "${OVERLAYS[@]}"; do
        run keel manifest validate --kind overlay "$name"
        echo "keel manifest validate --kind overlay $name: $status $output"
        [ "$status" -eq 0 ]
    done
}

# keel runs an overlay's state hook only when its manifest declares it
# (hooks.state, keel 0.15.0, the erratum of docs/manifest-v1.md)
@test "the coraza manifest declares its state hook, the one the package ships" {
    run python3 -c 'import yaml
print(yaml.safe_load(open("/usr/share/keel/overlays/coraza.yaml"))["hooks"]["state"]["path"])'
    [ "$output" = /usr/lib/keel/overlays/coraza/state ]
    [ -x "$output" ]
}

@test "keel manifest validate accepts every manifest installed on this machine" {
    run keel manifest validate
    echo "$output"
    [ "$status" -eq 0 ]
}

# ------------------------------------------------------------ Nginx

@test "nginx is enabled and active, the state of every installation mode" {
    run systemctl is-enabled nginx.service
    [ "$output" = enabled ]
    run systemctl is-active nginx.service
    [ "$output" = active ]
}

@test "/keel-health answers 204 on the IPv6 and the IPv4 loopback" {
    answers 204 "http://[::1]/keel-health"
    answers 204 "http://127.0.0.1/keel-health"
}

@test "/keel-health does not answer 204 on the machine's own addresses" {
    local address found=0
    for address in $(own_addresses); do
        found=1
        run code "http://$address/keel-health"
        echo "$address: $output"
        [ "$output" != 204 ]
    done
    [ "$found" -eq 1 ]
}

@test "Debian's default site still answers on the machine's own addresses" {
    local address
    for address in $(own_addresses); do
        answers 200 "http://$address/"
    done
}

@test "nginx.conf is nginx-common's, byte for byte" {
    local sum
    sum="$(dpkg-query -W -f='${Conffiles}\n' nginx-common \
        | awk '$1 == "/etc/nginx/nginx.conf" { print $2 }')"
    [ -n "$sum" ]
    [ "$(md5sum < /etc/nginx/nginx.conf | cut -d' ' -f1)" = "$sum" ]
}

@test "the streams drop-in gives Nginx a stream block reading streams-enabled" {
    nginx -t
    run nginx -T
    [[ "$output" == *"stream {"* ]]
    [[ "$output" == *"include /etc/nginx/streams-enabled/*;"* ]]
    [ -d /etc/nginx/streams-available ]
    [ -d /etc/nginx/streams-enabled ]
}

@test "/run/nginx exists for the sockets of Keel Web's internal hops" {
    [ -d /run/nginx ]
    [ "$(stat -c '%U %a' /run/nginx)" = "root 755" ]
}

# ------------------------------------------------------------ Coraza, off

@test "Coraza is installed and not loaded: no link, no worker maps the engine" {
    [ -f /usr/lib/nginx/modules/ngx_http_coraza_module.so ]
    assert_coraza_off
}

@test "a first install removes the link the module package made with it" {
    dpkg -P keel-overlay-coraza
    apt-get purge -y -q libnginx-mod-http-coraza
    [ ! -L "$MODULE_LINK" ]

    apt-get install -y -q --no-install-recommends \
        "$(deb_of libnginx-mod-http-coraza)" "$(deb_of keel-overlay-coraza)"

    [ ! -L "$MODULE_LINK" ]
    [ ! -L "$MODULE_LINK.removed" ]
    [ ! -e "$KEPT_CORAZA" ]
    assert_coraza_off
}

@test "a first install on a live system leaves a module link made before it" {
    dpkg -P keel-overlay-coraza
    ln -s /usr/share/nginx/modules-available/mod-http-coraza.conf "$MODULE_LINK"

    dpkg -i "$(deb_of keel-overlay-coraza)"

    [ -L "$MODULE_LINK" ]
    [ ! -e "$KEPT_CORAZA" ]
}

@test "in an image build a first install removes a module link made before it" {
    dpkg -P keel-overlay-coraza
    ln -s /usr/share/nginx/modules-available/mod-http-coraza.conf "$MODULE_LINK"

    as_image_build dpkg -i "$(deb_of keel-overlay-coraza)"

    [ ! -L "$MODULE_LINK" ]
    [ ! -e "$KEPT_CORAZA" ]
}

@test "an upgrade of the module package keeps Coraza off" {
    dpkg -i "$(with_version "$(deb_of libnginx-mod-http-coraza)" 99:0-keeltest1)"
    assert_coraza_off
    apt-get install -y -q --allow-downgrades "$(deb_of libnginx-mod-http-coraza)"
}

# ------------------------------------------------------------ Coraza, on

@test "state enabled loads the module and the WAF blocks the manifest's probe" {
    run "$STATE" enabled
    echo "$output"
    [ "$status" -eq 0 ]
    [ -L "$MODULE_LINK" ]
    [ -L "$WAF_LINK" ]
    workers_map libcoraza.so
    answers 403 "$PROBE"
    answers 204 "$HEALTH"
    # the WAF covers every server of the http block, Debian's default too
    local address
    for address in $(own_addresses); do
        answers 403 "http://$address/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
    done
}

# Keel-Linux/libnginx-mod-http-coraza#2: with the response headers held
# for phase 4 and sendfile on, a static file asked for with gzip came back
# as an empty gzip stream. Debian's default page, on the machine's own
# addresses, with and without gzip.
@test "with Coraza on, a static page asked for with gzip comes back whole" {
    "$STATE" enabled
    local address plain zipped
    for address in $(own_addresses); do
        plain=$(curl --globoff --silent --max-time 5 "http://$address/" | wc -c)
        zipped=$(curl --globoff --silent --max-time 5 --header 'Accept-Encoding: gzip' \
            "http://$address/" | gzip -dc | wc -c)
        echo "$address: $plain bytes plain, $zipped through gzip"
        [ "$plain" -gt 0 ]
        [ "$zipped" -eq "$plain" ]
    done
}

@test "state enabled a second time changes nothing" {
    "$STATE" enabled
    run "$STATE" enabled
    [ "$status" -eq 0 ]
    [ "$output" = "coraza: unchanged (enabled: the probe got 403 and /keel-health 204)" ]
}

@test "state disabled unloads the module and the probe passes again" {
    "$STATE" enabled
    run "$STATE" disabled
    echo "$output"
    [ "$status" -eq 0 ]
    assert_coraza_off
    answers 204 "$HEALTH"
}

@test "a remove takes Coraza out of Nginx, and a reinstall leaves it off" {
    "$STATE" enabled

    dpkg -r keel-overlay-coraza

    # the links are gone and the trigger reloaded Nginx without the module,
    # so autoremoving the module or the rule set cannot break a reload
    assert_coraza_off
    answers 204 "$HEALTH"
    nginx -t
    dpkg -i "$(deb_of keel-overlay-coraza)"
    assert_coraza_off
}

# coreruleset rebuilt under a higher version, with RULE added as a rule
# file of its own when given
coreruleset_upgrade() {
    local tree
    tree="$(mktemp -d "$BATS_TEST_TMPDIR/crs.XXXXXX")"
    dpkg-deb -R "$(deb_of coreruleset)" "$tree/root"
    if [ -n "${1:-}" ]; then
        echo "$1" > "$tree/root/usr/share/coreruleset/rules/REQUEST-899-KEEL-TEST.conf"
        (cd "$tree/root" && find usr -type f -exec md5sum {} + > DEBIAN/md5sums)
    fi
    awk '/^Version: / { $0 = "Version: 99:0-keeltest1" } { print }' \
        "$tree/root/DEBIAN/control" > "$tree/control"
    mv "$tree/control" "$tree/root/DEBIAN/control"
    dpkg-deb -b "$tree/root" "$tree/coreruleset.deb" >&2
    echo "$tree/coreruleset.deb"
}

@test "an upgrade of the rule set under an enabled Coraza is rechecked and kept" {
    "$STATE" enabled

    run dpkg -i "$(coreruleset_upgrade)"

    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"coraza: rechecked: the probe got 403"* ]]
    [ -L "$MODULE_LINK" ]
    [ -L "$WAF_LINK" ]
    answers 403 "$PROBE"
}

@test "an upgrade of the rule set that kills the workers turns Coraza off" {
    "$STATE" enabled

    run dpkg -i "$(coreruleset_upgrade 'SecRule ARGS "@rx (" "id:1000,phase:1,deny"')"

    echo "$output"
    # the upgrade itself succeeds; Coraza is off and Nginx answers
    [ "$status" -eq 0 ]
    [[ "$output" == *"no nginx worker is running"* ]]
    [[ "$output" == *"rolled back, Coraza is off"* ]]
    assert_coraza_off
    answers 204 "$HEALTH"
}

@test "a rule Coraza refuses is rolled back: Nginx answers and Coraza stays off" {
    # upstream coraza-nginx #139: this passes nginx -t, then every worker
    # dies at start and every request hangs
    cp "$RULES" "$BATS_TEST_TMPDIR/rules"
    echo 'SecRule ARGS "@rx (" "id:1000,phase:1,deny"' >> "$RULES"
    nginx -t

    run "$STATE" enabled

    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no nginx worker is running"* ]]
    [[ "$output" == *"rolled back"* ]]
    assert_coraza_off
    answers 204 "$HEALTH"
}

# ------------------------------------------------------------ Anubis

@test "Anubis is installed and off: its unit disabled and inactive, no key" {
    [ -x /usr/bin/anubis ]
    run systemctl is-enabled "$ANUBIS"
    [ "$output" = disabled ]
    run systemctl is-active "$ANUBIS"
    [ "$output" = inactive ]
    [ ! -e "$KEY" ]
    run code "http://[::1]:8923/"
    [ "$output" = 000 ]
}

@test "the first start of the unit makes the signing key, root's alone" {
    systemctl enable --now "$ANUBIS"
    run systemctl is-active "$ANUBIS"
    [ "$output" = active ]
    [[ "$(cat "$KEY")" =~ ^[0-9a-f]{64}$ ]]
    [ "$(stat -c '%U %a' "$KEY")" = "root 600" ]
}

@test "Anubis listens on the IPv6 loopback only" {
    systemctl enable --now "$ANUBIS"
    # any answer at all, within ten seconds of the start
    local try got=000
    for try in $(seq 10); do
        got="$(code --header "X-Real-IP: ::1" "http://[::1]:8923/")"
        [ "$got" != 000 ] && break
        sleep 1
    done
    echo "[::1]:8923: $got"
    [ "$got" != 000 ]
    run code "http://127.0.0.1:8923/"
    [ "$output" = 000 ]
    local address
    for address in $(own_addresses); do
        run code "http://$address:8923/"
        [ "$output" = 000 ]
    done
}

@test "a restart keeps the signing key" {
    systemctl enable --now "$ANUBIS"
    local before
    before="$(cat "$KEY")"
    systemctl restart "$ANUBIS"
    [ "$(cat "$KEY")" = "$before" ]
}

@test "Nginx proxies to Anubis: a browser is challenged, a client it allows passes" {
    systemctl enable --now "$ANUBIS"
    cat > "$TEST_SITE" <<'EOF'
server {
    listen [::1]:8081;
    location / {
        include /etc/nginx/snippets/keel-anubis.conf;
    }
}
server {
    listen unix:/run/nginx/keel-app.sock;
    location / {
        return 200 "behind anubis\n";
    }
}
EOF
    nginx -t
    systemctl reload nginx.service
    answers 200 "http://[::1]:8081/" --user-agent curl/8.14.1

    run curl --globoff --silent --max-time 5 --user-agent curl/8.14.1 \
        "http://[::1]:8081/"
    [ "$output" = "behind anubis" ]
    run curl --globoff --silent --max-time 5 \
        --user-agent "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0" \
        "http://[::1]:8081/"
    echo "$output" | head -5
    [[ "$output" != *"behind anubis"* ]]
    [[ "$output" == *anubis* ]]
}

@test "the key file the spec names is the key, and none is made" {
    install -D -m 0600 /dev/null "$PRIMARY_KEY"
    head -c 32 /dev/urandom | od -A n -v -t x1 | tr -d ' \n' > "$PRIMARY_KEY"
    local line="  anubis_signing_key: {file: $PRIMARY_KEY}"
    if [ -f "$SPEC" ]; then
        # a machine with a spec, the Core image's: the secret is added to it
        cp -p "$SPEC" "$BATS_TEST_TMPDIR/instance.yaml"
        awk -v line="$line" '{ print } /^secrets:/ { print line }' \
            "$BATS_TEST_TMPDIR/instance.yaml" > "$SPEC"
    else
        : > "$BATS_TEST_TMPDIR/no-spec"
        install -D -m 0600 /dev/null "$SPEC"
        printf '%s\n' "version: 1" "secrets:" "$line" > "$SPEC"
    fi

    systemctl enable --now "$ANUBIS"

    [ "$(readlink "$KEY")" = "$PRIMARY_KEY" ]
    run systemctl is-active "$ANUBIS"
    [ "$output" = active ]
}

@test "a node marked to take the key from its primary makes none and does not start" {
    : > "$KEY.from-primary"

    run systemctl enable --now "$ANUBIS"

    [ "$status" -ne 0 ]
    [ ! -e "$KEY" ]
    run systemctl is-active "$ANUBIS"
    [ "$output" != active ]
    run journalctl -u keel-overlay-anubis-key.service -n 5 --no-pager
    [[ "$output" == *"comes from the primary"* ]]
}

@test "a purge of the overlay stops and disables Anubis and deletes the key" {
    systemctl enable --now "$ANUBIS"
    [ -f "$KEY" ]

    dpkg -P keel-overlay-anubis

    run systemctl is-enabled "$ANUBIS"
    [ "$output" = disabled ]
    run systemctl is-active "$ANUBIS"
    [ "$output" = inactive ]
    [ ! -e "$KEY" ]
}

@test "keel apply can still enable every unit: none is masked" {
    local unit
    for unit in nginx.service "$ANUBIS"; do
        run systemctl is-enabled "$unit"
        [ "$output" != masked ]
    done
}
