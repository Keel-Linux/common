#!/usr/bin/env bats
# Tests for the resolvconf hooks for ifupdown-ng (common#15), in
# overlays/turnkey.d/resolvconf-ifupdown-ng:
#   etc/network/if-up.d/000resolvconf-ifupdown-ng
#   etc/network/if-down.d/resolvconf-ifupdown-ng
#
# resolvconf's own if-up.d hook exits unless ADDRFAM is inet or inet6, and
# ifupdown-ng never sets ADDRFAM, so the name servers of a static stanza
# never reached /etc/resolv.conf. These hooks do what that one would, only
# when ADDRFAM is missing.
#
# resolvconf is a stub here that records its arguments and what it was fed:
# the real one needs root and /run. The same hooks against the real
# ifupdown-ng and resolvconf are run in an overlay of the core layer; the
# command is in COVERAGE.md.
#
# Refutations are "run !", never a bare "!" (docs/traps.md).

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO="$(cd "$TESTS_DIR/.." && pwd)"
    SHIPPED="$REPO/overlays/turnkey.d/resolvconf-ifupdown-ng/etc/network"
    UP="$SHIPPED/if-up.d/000resolvconf-ifupdown-ng"
    DOWN="$SHIPPED/if-down.d/resolvconf-ifupdown-ng"

    export RESOLVCONF="$BATS_TEST_TMPDIR/resolvconf"
    cat > "$RESOLVCONF" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/calls"
# resolvconf reads a record only for -a; -d gets nothing on standard input
[ "\$1" = -a ] && cat > "$BATS_TEST_TMPDIR/stdin"
exit \${RESOLVCONF_EXIT:-0}
STUB
    chmod +x "$RESOLVCONF"

    # ifupdown-ng's ifquery, as measured on the core layer: one line per
    # stanza that carries the property. Absent unless a test writes it.
    export IFQUERY="$BATS_TEST_TMPDIR/ifquery"

    # what ifupdown-ng exports to an addon script (measured on the core
    # layer: IFACE, METHOD, MODE, PHASE and IF_<OPTION>, never ADDRFAM)
    unset ADDRFAM IF_DNS_NAMESERVERS IF_DNS_NAMESERVER IF_DNS_SEARCH \
        IF_DNS_DOMAIN IF_DNS_SORTLIST IF_DNS_OPTIONS
    export IFACE=eth0 METHOD=none MODE=start PHASE=up
}

calls() { cat "$BATS_TEST_TMPDIR/calls" 2>/dev/null || true; }
fed() { cat "$BATS_TEST_TMPDIR/stdin" 2>/dev/null || true; }

@test "the name servers of a static stanza reach resolvconf under ifupdown-ng" {
    IF_DNS_NAMESERVERS="2001:db8:1::53 192.0.2.53" run "$UP"
    [ "$status" -eq 0 ]
    [ "$(calls)" = "-a eth0.inet" ]
    [ "$(fed)" = "$(printf 'nameserver 2001:db8:1::53\nnameserver 192.0.2.53')" ]
}

@test "search, domain, sortlist and options are passed as resolvconf's hook passes them" {
    IF_DNS_DOMAIN=example.org IF_DNS_SEARCH="example.org corp.example" \
        IF_DNS_SORTLIST="2001:db8::/32" IF_DNS_OPTIONS="rotate" \
        IF_DNS_NAMESERVERS="2001:db8:1::53" run "$UP"
    [ "$status" -eq 0 ]
    [ "$(fed)" = "$(printf '%s\n' 'domain example.org' \
        'search example.org corp.example' 'sortlist 2001:db8::/32' \
        'options rotate' 'nameserver 2001:db8:1::53')" ]
}

@test "dns-nameserver lines, one per line, are each passed" {
    IF_DNS_NAMESERVER="$(printf '2001:db8:1::53\n2001:db8:1::54')" run "$UP"
    [ "$status" -eq 0 ]
    [ "$(fed)" = "$(printf 'nameserver 2001:db8:1::53\nnameserver 2001:db8:1::54')" ]
}

@test "a list the environment gives newline separated is split into addresses" {
    IF_DNS_NAMESERVERS="$(printf '192.0.2.53\n2001:db8:1::53')" run "$UP"
    [ "$(fed)" = "$(printf 'nameserver 192.0.2.53\nnameserver 2001:db8:1::53')" ]
}

# ifquery ARGS...: an ifquery stub answering from $BATS_TEST_TMPDIR/props/NAME
ifquery_answers() {
    mkdir -p "$BATS_TEST_TMPDIR/props"
    cat > "$IFQUERY" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/ifquery.calls"
while [ "\$#" -gt 0 ]; do
    case "\$1" in -p) prop=\$2; shift 2 ;; *) shift ;; esac
done
cat "$BATS_TEST_TMPDIR/props/\$prop" 2>/dev/null
exit 0
STUB
    chmod +x "$IFQUERY"
}

@test "an interface with an inet and an inet6 stanza passes both lists" {
    # ifupdown-ng merges the stanzas and exports only the last list; the
    # IPv4 name server was lost until ifquery was asked (measured)
    ifquery_answers
    printf '192.0.2.53\n2001:db8:1::53 2001:db8:1::54\n' \
        > "$BATS_TEST_TMPDIR/props/dns-nameservers"
    IF_DNS_NAMESERVERS="2001:db8:1::53 2001:db8:1::54" run "$UP"
    [ "$status" -eq 0 ]
    [ "$(fed)" = "$(printf '%s\n' 'nameserver 192.0.2.53' \
        'nameserver 2001:db8:1::53' 'nameserver 2001:db8:1::54')" ]
}

@test "ifquery is asked without taking ifup's lock, and for this interface" {
    ifquery_answers
    echo 192.0.2.53 > "$BATS_TEST_TMPDIR/props/dns-nameservers"
    INTERFACES_FILE=/etc/network/interfaces.test run "$UP"
    grep -q -- "-l -i /etc/network/interfaces.test -p dns-nameservers eth0" \
        "$BATS_TEST_TMPDIR/ifquery.calls"
}

@test "every dns option is asked of ifquery, and a repeated one joined" {
    ifquery_answers
    echo example.org > "$BATS_TEST_TMPDIR/props/dns-domain"
    printf 'example.org\ncorp.example\n' > "$BATS_TEST_TMPDIR/props/dns-search"
    echo 2001:db8:1::53 > "$BATS_TEST_TMPDIR/props/dns-nameserver"
    run "$UP"
    [ "$(fed)" = "$(printf '%s\n' 'domain example.org' \
        'search example.org corp.example' 'nameserver 2001:db8:1::53')" ]
}

@test "without ifquery the environment is used" {
    IF_DNS_NAMESERVERS=192.0.2.53 run "$UP"
    [ "$(fed)" = "nameserver 192.0.2.53" ]
}

@test "classic ifupdown sets ADDRFAM, and resolvconf's own hook is left to it" {
    ADDRFAM=inet IF_DNS_NAMESERVERS=192.0.2.53 run "$UP"
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
    ADDRFAM=inet6 run "$DOWN"
    [ -z "$(calls)" ]
}

@test "an interface with no dns option registers nothing" {
    IFACE=lo run "$UP"
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
}

@test "without resolvconf the hooks do nothing and succeed" {
    RESOLVCONF="$BATS_TEST_TMPDIR/absent" IF_DNS_NAMESERVERS=192.0.2.53 run "$UP"
    [ "$status" -eq 0 ]
    RESOLVCONF="$BATS_TEST_TMPDIR/absent" run "$DOWN"
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
}

@test "a resolvconf that fails does not fail the interface" {
    RESOLVCONF_EXIT=1 IF_DNS_NAMESERVERS=192.0.2.53 run "$UP"
    [ "$status" -eq 0 ]
    RESOLVCONF_EXIT=1 run "$DOWN"
    [ "$status" -eq 0 ]
}

@test "bringing the interface down withdraws what it registered" {
    PHASE=down MODE=stop run "$DOWN"
    [ "$status" -eq 0 ]
    [ "$(calls)" = "-d eth0.inet" ]
}

@test "the hooks are executable, as run-parts requires" {
    [ -x "$UP" ]
    [ -x "$DOWN" ]
}

@test "both hooks are shellcheck clean" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    run shellcheck "$UP" "$DOWN"
    [ "$status" -eq 0 ]
}
