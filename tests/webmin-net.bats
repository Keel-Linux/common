#!/usr/bin/env bats
# Tests for overlays/turnkey.d/webmin-net/usr/local/sbin/webmin-net-read-only,
# its apt hook and conf/turnkey.d/webmin-net: Webmin's Network
# Configuration module is installed, and no Webmin user, root or created
# later, can rewrite the network configuration that inithooks and
# confconsole own (turnkeylinux/tracker#2118).
#
# The module under test is the real one, webmin-net 2.660.turnkey0 as a
# core build installs it, run through its own CGIs over a scratch root
# (tests/webmin-net.bash). A save is made the way a browser makes it: the
# edit page is rendered and its form submitted as the page filled it in.
# Webmin users are created the same way, through the acl module's
# edit_user.cgi and save_user.cgi.
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
    WEBMIN_PRISTINE=$(fetch_webmin "$BATS_FILE_TMPDIR/webmin")
    export WEBMIN_PRISTINE
}

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    OVERLAY="$TESTS_DIR/../overlays/turnkey.d/webmin-net"
    SCRIPT="$OVERLAY/usr/local/sbin/webmin-net-read-only"
    HOOK="$OVERLAY/etc/apt/apt.conf.d/80webmin-net-read-only"
    CONF="$TESTS_DIR/../conf/turnkey.d/webmin-net"
    PLAN="$TESTS_DIR/../plans/turnkey/base"
    scratch_root interfaces-core
}

# default_value KEY: the value the module's default ACL gives KEY
default_value() {
    sed -n "s/^$1=//p" "$WEBMIN_TREE/net/defaultacl"
}

# refused_with TEXT: the last CGI output carried Webmin's refusal TEXT
refused_with() {
    [[ "$output" == *"You are not allowed to $1"* ]]
}

# new_user NAME: creates Webmin user NAME with the Network Configuration
# module, as root does it on the Webmin Users page
new_user() {
    webmin_net_run "WEBMIN_MODULE=acl press_save edit_user.cgi '' save_user.cgi \
        name=$1 pass_def=0 pass=Correct-Horse-2001 mod=net"
    grep -q "^$1: net$" "$WEBMIN_CONFIG/webmin.acl"
}

# hook_command: the command apt runs after every dpkg run, as apt itself
# reads it from the hook file and no other configuration
hook_command() {
    apt-config -o Dir::Etc::main=/dev/null -o Dir::Etc::parts=/nonexistent \
        -c "$HOOK" dump DPkg::Post-Invoke \
        | sed -n 's/^DPkg::Post-Invoke:: "\(.*\)";$/\1/p'
}

@test "the core plan installs the Network Configuration module" {
    run grep -cE '^webmin-net([[:space:]]|$)' "$PLAN"
    [ "$output" = "1" ]
}

@test "the build runs the script" {
    PATH="$OVERLAY/usr/local/sbin:$PATH" run "$CONF"
    [ "$status" -eq 0 ]
    [ "$(default_value ifcs)" = "1" ]
}

@test "the default ACL leaves interfaces and DNS to view, routing and apply off" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(default_value ifcs)" = "1" ]
    [ "$(default_value routes)" = "0" ]
    [ "$(default_value dns)" = "1" ]
    [ "$(default_value apply)" = "0" ]
}

@test "running the script twice writes each setting once" {
    lines_before=$(grep -c '' "$WEBMIN_TREE/net/defaultacl")
    "$SCRIPT"
    "$SCRIPT"
    run grep -c '' "$WEBMIN_TREE/net/defaultacl"
    [ "$output" = "$lines_before" ]
}

@test "the script keeps the defaults it does not own" {
    "$SCRIPT"
    [ "$(default_value hosts)" = "2" ]
    [ "$(default_value sysinfo)" = "1" ]
}

@test "without the module the script does nothing and succeeds" {
    rm -rf "$WEBMIN_TREE/net"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$WEBMIN_TREE/net" ]
}

@test "without Webmin at all the script does nothing and succeeds" {
    rm "$WEBMIN_CONFIG/miniserv.conf"
    unset WEBMIN_ROOT
    run "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "the script finds the Webmin root in miniserv.conf" {
    printf 'root=%s\n' "$WEBMIN_TREE" > "$WEBMIN_CONFIG/miniserv.conf"
    unset WEBMIN_ROOT
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(default_value ifcs)" = "1" ]
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

@test "without the script, a Webmin user created later rewrites eth0 as well" {
    new_user alice
    run webmin_net_run 'WEBMIN_USER=alice press_save edit_bifc.cgi idx=1 save_bifc.cgi'
    [ "$status" -eq 0 ]
    run grep -c 'iface eth0 inet6' "$ROOT/etc/network/interfaces"
    [ "$output" = "0" ]
}

@test "with the script, saving eth0 is refused and the core file is unchanged" {
    "$SCRIPT"
    run webmin_net_run 'press_save edit_bifc.cgi idx=1 save_bifc.cgi'
    refused_with "edit this network interface"
    interfaces_unchanged
}

@test "with the script, a changed IPv4 address on inithooks' static file is refused" {
    scratch_root interfaces-static
    "$SCRIPT"
    run webmin_net_run 'press_save edit_bifc.cgi idx=1 save_bifc.cgi address=192.0.2.11'
    refused_with "edit this network interface"
    interfaces_unchanged
}

@test "with the script, a changed IPv6 address on confconsole's static6 file is refused" {
    scratch_root interfaces-static6
    "$SCRIPT"
    run webmin_net_run 'press_save edit_bifc.cgi idx=1 save_bifc.cgi address6_0=2001:db8:1::11'
    refused_with "edit this network interface"
    interfaces_unchanged
}

@test "with the script, deleting eth0 is refused" {
    "$SCRIPT"
    run webmin_net_run 'cgi delete_bifcs.cgi b=eth0'
    refused_with "edit this network interface"
    interfaces_unchanged
}

@test "with the script, bringing up a new live interface is refused" {
    "$SCRIPT"
    run webmin_net_run 'cgi save_aifc.cgi "new=1&name=eth0&virtual=1&address=192.0.2.12&netmask=255.255.255.0&up=1"'
    refused_with "edit network interfaces"
}

@test "with the script, the DNS page is refused and hostname and resolver are unchanged" {
    scratch_root interfaces-static
    "$SCRIPT"
    run webmin_net_run 'press_save list_dns.cgi "" save_dns.cgi hostname=other nameserver_0=2001:db8:1::54; hostname'
    refused_with "edit DNS client settings"
    [[ "${lines[-1]}" != "other" ]]
    interfaces_unchanged
    [ "$(cat "$ROOT/etc/hostname")" = "core" ]
    [ -L "$ROOT/etc/resolv.conf" ]
}

@test "with the script, saving boot-time routing is refused" {
    scratch_root interfaces-static
    "$SCRIPT"
    run webmin_net_run 'cgi save_routes.cgi "gateway_def=1&gateway6_def=1&forward=0"'
    refused_with "edit routing and gateways"
    interfaces_unchanged
}

@test "with the script, adding a live route is refused" {
    "$SCRIPT"
    # a dummy eth0 on 2001:db8:1::/64, on which the route would be added:
    # measured, with routes=1 the same request adds it
    run webmin_net_run 'ip link add eth0 type dummy && ip link set eth0 up &&
        ip -6 addr add 2001:db8:1::10/64 dev eth0 nodad &&
        cgi create_route.cgi "dest_def=0&dest=2001:db8:2::&netmask_def=1&via=1&gateway=2001:db8:1::1";
        ip -6 route show'
    refused_with "edit routing and gateways"
    [[ "$output" != *"2001:db8:2::"*"via"* ]]
}

@test "with the script, deleting a live route is refused" {
    "$SCRIPT"
    run webmin_net_run 'cgi delete_routes.cgi "d=0&delete=1"'
    refused_with "edit routing and gateways"
}

@test "with the script, applying the configuration is refused" {
    "$SCRIPT"
    run webmin_net_run 'cgi apply.cgi ""'
    refused_with "apply the configuration"
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

@test "with the script, a Webmin user created later cannot save eth0 either" {
    "$SCRIPT"
    new_user alice
    run webmin_net_run 'WEBMIN_USER=alice press_save edit_bifc.cgi idx=1 save_bifc.cgi'
    refused_with "edit this network interface"
    interfaces_unchanged
}

@test "apt runs the script after every dpkg run" {
    run hook_command
    [ "$output" = "if [ -x /usr/local/sbin/webmin-net-read-only ]; then /usr/local/sbin/webmin-net-read-only; fi" ]
}

@test "an upgrade of webmin-net resets the default ACL, and the apt hook restores it" {
    "$SCRIPT"
    # what webmin-net's postinst runs on every install and upgrade
    webmin_net_run 'cd /opt/webmin && PERL5LIB=/opt/webmin ./install-module.pl module-archives/net.wbm.gz'
    [ "$(default_value ifcs)" = "2" ]

    sh -c "$(hook_command | sed "s|/usr/local/sbin/webmin-net-read-only|$SCRIPT|g")"
    new_user bob
    run webmin_net_run 'WEBMIN_USER=bob press_save edit_bifc.cgi idx=1 save_bifc.cgi'
    refused_with "edit this network interface"
    interfaces_unchanged
}
