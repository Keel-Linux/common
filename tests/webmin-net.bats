#!/usr/bin/env bats
# Tests for conf/turnkey.d/webmin-net: Webmin's Network Configuration
# module is installed, and cannot rewrite the network configuration that
# inithooks and confconsole own (turnkeylinux/tracker#2118).
#
# The module under test is the real one, webmin-net 2.660.turnkey0 as a
# core build installs it, run through its own CGIs over a scratch root
# (tests/webmin-net.bash). A save is made the way a browser makes it: the
# edit page is rendered and its form submitted as the page filled it in.
#
# The interfaces fixtures are files Keel writes, not hand-written ones:
#   interfaces-core     /etc/network/interfaces of the built core layer
#                       (IPv4 and IPv6 by DHCP on eth0 and eth1)
#   interfaces-static   inithooks lib/ipconfig.sh, IP_CONFIG=static and
#                       IP6_CONFIG=static, as firstboot.d/01ipconfig
#                       renders them
#   interfaces-static6  confconsole ifutil NetworkInterfaces.set_static6 on
#                       interfaces-core

bats_require_minimum_version 1.5.0

load helpers
load webmin-net

setup_file() {
    WEBMIN_TREE=$(fetch_webmin "$BATS_FILE_TMPDIR/webmin")
    export WEBMIN_TREE
}

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../conf/turnkey.d/webmin-net"
    PLAN="$TESTS_DIR/../plans/turnkey/base"
    scratch_root interfaces-core
}

# acl_value KEY: the value root's ACL for the module gives KEY
acl_value() {
    sed -n "s/^$1=//p" "$WEBMIN_CONFIG/net/root.acl"
}

@test "the core plan installs the Network Configuration module" {
    run grep -cE '^webmin-net([[:space:]]|$)' "$PLAN"
    [ "$output" = "1" ]
}

@test "the script leaves interfaces, routing and DNS to view and apply off" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(acl_value ifcs)" = "1" ]
    [ "$(acl_value routes)" = "1" ]
    [ "$(acl_value dns)" = "1" ]
    [ "$(acl_value apply)" = "0" ]
}

@test "running the script twice writes each setting once" {
    "$SCRIPT"
    "$SCRIPT"
    run grep -c '' "$WEBMIN_CONFIG/net/root.acl"
    [ "$output" = "4" ]
}

@test "the script keeps the settings of root's ACL it does not own" {
    printf 'hosts=1\nifcs=2\n' > "$WEBMIN_CONFIG/net/root.acl"
    "$SCRIPT"
    [ "$(acl_value hosts)" = "1" ]
    [ "$(acl_value ifcs)" = "1" ]
}

# The hazard itself, measured on the module as TurnKey ships it: this is
# what the script is for, and what the tests below would miss if the
# scratch root did not reproduce it.
@test "without the script, saving eth0 unchanged loses its IPv6 stanza" {
    run webmin_net_run 'press_save edit_bifc.cgi idx=1 save_bifc.cgi'
    [ "$status" -eq 0 ]
    run grep -c 'iface eth0 inet6' "$ROOT/etc/network/interfaces"
    [ "$output" = "0" ]
}

@test "without the script, saving a static eth0 unchanged loses its name servers" {
    scratch_root interfaces-static
    run webmin_net_run 'press_save edit_bifc.cgi idx=1 save_bifc.cgi'
    [ "$status" -eq 0 ]
    run grep -c 'dns-nameservers' "$ROOT/etc/network/interfaces"
    [ "$output" = "0" ]
}

@test "with the script, saving eth0 is refused and the core file is unchanged" {
    "$SCRIPT"
    run webmin_net_run 'press_save edit_bifc.cgi idx=1 save_bifc.cgi'
    [[ "$output" == *"You are not allowed to edit this network interface"* ]]
    interfaces_unchanged
}

@test "with the script, a changed IPv4 address on inithooks' static file is refused" {
    scratch_root interfaces-static
    "$SCRIPT"
    run webmin_net_run 'press_save edit_bifc.cgi idx=1 save_bifc.cgi address=192.0.2.11'
    [[ "$output" == *"You are not allowed to edit this network interface"* ]]
    interfaces_unchanged
}

@test "with the script, a changed IPv6 address on confconsole's static6 file is refused" {
    scratch_root interfaces-static6
    "$SCRIPT"
    run webmin_net_run 'press_save edit_bifc.cgi idx=1 save_bifc.cgi address6_0=2001:db8:1::11'
    [[ "$output" == *"You are not allowed to edit this network interface"* ]]
    interfaces_unchanged
}

@test "with the script, deleting eth0 is refused" {
    "$SCRIPT"
    run webmin_net_run 'cgi delete_bifcs.cgi b=eth0'
    [[ "$output" == *"You are not allowed to edit this network interface"* ]]
    interfaces_unchanged
}

@test "with the script, the DNS page is refused and hostname and resolver are unchanged" {
    scratch_root interfaces-static
    "$SCRIPT"
    run webmin_net_run 'press_save list_dns.cgi "" save_dns.cgi hostname=other nameserver_0=2001:db8:1::54; hostname'
    [[ "$output" == *"You are not allowed to edit DNS client settings"* ]]
    [[ "${lines[-1]}" != "other" ]]
    interfaces_unchanged
    [ "$(cat "$ROOT/etc/hostname")" = "core" ]
    [ -L "$ROOT/etc/resolv.conf" ]
}

@test "with the script, the routing page is refused" {
    scratch_root interfaces-static
    "$SCRIPT"
    run webmin_net_run 'press_save list_routes.cgi "" save_routes.cgi gateway_def=1'
    [[ "$output" == *"You are not allowed to edit routing and gateways"* ]]
    interfaces_unchanged
}

@test "with the script, applying the configuration is refused" {
    "$SCRIPT"
    run webmin_net_run 'cgi apply.cgi ""'
    [[ "$output" == *"You are not allowed to apply the configuration"* ]]
}

@test "with the script, the module still shows eth0 and its addresses" {
    scratch_root interfaces-static
    "$SCRIPT"
    run webmin_net_run 'cgi list_ifcs.cgi mode=boot'
    [ "$status" -eq 0 ]
    [[ "$output" == *"eth0"* ]]
    [[ "$output" == *"192.0.2.10"* ]]
    [[ "$output" == *"2001:db8:1::10"* ]]
}

@test "with the script, /etc/hosts can still be edited" {
    "$SCRIPT"
    run webmin_net_run 'press_save edit_host.cgi new=1 save_host.cgi address=2001:db8:1::20 hosts=peer'
    [ "$status" -eq 0 ]
    grep -qE '^2001:db8:1::20[[:space:]]+peer$' "$ROOT/etc/hosts"
    interfaces_unchanged
}
