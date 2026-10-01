#!/usr/bin/env bats
# Tests for packages/coraza/state, the hook that turns the Coraza overlay
# on and off (decision 0041, first implementation, step 6).
#
# nginx, curl and pgrep are stubs from tests/stubs-nginx (a directory of
# their own, so no other suite's PATH meets them) that record their
# arguments in STUB_LOG. The curl stub answers as the Nginx of a Keel Web
# machine would, from the links in the scratch /etc/nginx: with Coraza's
# configuration linked, the probe gets 403; without it, 204. With
# STUB_CORAZA_KILLS_WORKERS set and the module linked, every worker has
# died, as upstream coraza-nginx #139 makes them when a rule Coraza refuses
# passed `nginx -t`: pgrep finds no worker and every request times out.
# The real Nginx, module and rule set are tests/overlay-web.bats'.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../packages/coraza/state"
    export PATH="$TESTS_DIR/stubs-nginx:$PATH"
    export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
    : > "$STUB_LOG"
    unset STUB_NGINX_T STUB_CORAZA_KILLS_WORKERS STUB_HEALTH

    export KEEL_NGINX_DIR="$BATS_TEST_TMPDIR/etc/nginx"
    export KEEL_CORAZA_MODULE_CONF="$BATS_TEST_TMPDIR/usr/share/nginx/modules-available/mod-http-coraza.conf"
    export KEEL_NGINX_PID="$BATS_TEST_TMPDIR/run/nginx.pid"
    export KEEL_CORAZA_TRIES=2
    export KEEL_CORAZA_INTERVAL=0
    export KEEL_CORAZA_LOCK="$BATS_TEST_TMPDIR/keel-overlay-coraza.lock"
    unset STUB_NGINX_RELOAD KEEL_CORAZA_LOCK_WAIT STUB_RELOAD_LAG
    mkdir -p "$KEEL_NGINX_DIR/modules-enabled" "$KEEL_NGINX_DIR/conf.d" \
        "$KEEL_NGINX_DIR/coraza" "${KEEL_CORAZA_MODULE_CONF%/*}" \
        "${KEEL_NGINX_PID%/*}"
    : > "$KEEL_CORAZA_MODULE_CONF"
    : > "$KEEL_NGINX_DIR/coraza/keel.conf"
    MODULE_LINK="$KEEL_NGINX_DIR/modules-enabled/50-mod-http-coraza.conf"
    WAF_LINK="$KEEL_NGINX_DIR/conf.d/keel-coraza.conf"
    nginx_running
}

teardown() {
    if [ -n "${MASTER:-}" ]; then
        kill "$MASTER" 2>/dev/null || true
    fi
    if [ -n "${HOLDER:-}" ]; then
        kill "$HOLDER" 2>/dev/null || true
    fi
}

# another run of the hook, holding the lock for SECONDS
lock_held() {
    flock "$KEEL_CORAZA_LOCK" sleep "$1" &
    HOLDER=$!
    until ! flock -n "$KEEL_CORAZA_LOCK" true; do sleep 0.1; done
}

# a live process stands for the master; its pid goes in the pid file
nginx_running() {
    sleep 300 &
    MASTER=$!
    echo "$MASTER" > "$KEEL_NGINX_PID"
}

nginx_stopped() {
    kill "$MASTER"
    wait "$MASTER" 2>/dev/null || true
    MASTER=
}

link_enabled() {
    ln -s "$KEEL_CORAZA_MODULE_CONF" "$MODULE_LINK"
    ln -s "$KEEL_NGINX_DIR/coraza/keel.conf" "$WAF_LINK"
}

assert_enabled_links() {
    [ "$(readlink "$MODULE_LINK")" = "$KEEL_CORAZA_MODULE_CONF" ]
    [ "$(readlink "$WAF_LINK")" = "$KEEL_NGINX_DIR/coraza/keel.conf" ]
}

assert_no_links() {
    [ ! -e "$MODULE_LINK" ]
    [ ! -L "$MODULE_LINK" ]
    [ ! -e "$WAF_LINK" ]
    [ ! -L "$WAF_LINK" ]
}

logged() {
    grep -qF -- "$1" "$STUB_LOG"
}

reloads() {
    grep -cxF "nginx -s reload" "$STUB_LOG" || true
}

# ------------------------------------------------------------ usage

@test "refuses to run without a state" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [ "$output" = "usage: state enabled|disabled|recheck" ]
    [ ! -s "$STUB_LOG" ]
}

@test "refuses a state that is not enabled or disabled" {
    run "$SCRIPT" on
    [ "$status" -eq 2 ]
    [ "$output" = "usage: state enabled|disabled|recheck" ]
    [ ! -s "$STUB_LOG" ]
}

# ------------------------------------------------------------ the lock

@test "waits for another run to finish before it starts" {
    lock_held 1
    run "$SCRIPT" enabled
    [ "$status" -eq 0 ]
    assert_enabled_links
}

@test "gives up, changing nothing, when another run keeps the lock" {
    export KEEL_CORAZA_LOCK_WAIT=1
    lock_held 30
    run "$SCRIPT" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"another run holds $KEEL_CORAZA_LOCK"* ]]
    assert_no_links
    [ ! -s "$STUB_LOG" ]
}

# ------------------------------------------------------------ enabled

@test "enabled links the module and the WAF, reloads, and checks the probe" {
    run "$SCRIPT" enabled
    echo "$output"
    [ "$status" -eq 0 ]
    assert_enabled_links
    [ "$(reloads)" -eq 1 ]
    logged "nginx -t"
    logged "keel-waf-probe"
    [[ "$output" == *"coraza: enabled: the probe got 403 and /keel-health 204"* ]]
}

@test "enabled tests the configuration before it reloads" {
    run "$SCRIPT" enabled
    [ "$status" -eq 0 ]
    [ "$(grep -n -m1 -xF 'nginx -t' "$STUB_LOG" | cut -d: -f1)" -lt \
      "$(grep -n -m1 -xF 'nginx -s reload' "$STUB_LOG" | cut -d: -f1)" ]
}

@test "enabled asks curl not to glob the IPv6 loopback address" {
    run "$SCRIPT" enabled
    [ "$status" -eq 0 ]
    logged "--globoff"
    logged "http://[::1]/keel-health"
}

@test "enabled refuses, changing nothing, while nginx is not running" {
    nginx_stopped
    run "$SCRIPT" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx is not running"* ]]
    assert_no_links
    [ ! -s "$STUB_LOG" ]
}

@test "enabled refuses while the pid file names no live process" {
    nginx_stopped
    echo 999999999 > "$KEEL_NGINX_PID"
    run "$SCRIPT" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx is not running"* ]]
    assert_no_links
}

@test "enabled when already enabled only checks the probe" {
    link_enabled
    run "$SCRIPT" enabled
    [ "$status" -eq 0 ]
    [ "$output" = "coraza: unchanged (enabled: the probe got 403 and /keel-health 204)" ]
    [ "$(reloads)" -eq 0 ]
    assert_enabled_links
}

@test "enabled when already enabled but not blocking fails and changes nothing" {
    link_enabled
    export STUB_CORAZA_KILLS_WORKERS=1
    run "$SCRIPT" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"coraza: enabled, but no nginx worker is running"* ]]
    [ "$(reloads)" -eq 0 ]
    assert_enabled_links
}

@test "enabled rolls back when nginx -t refuses the configuration" {
    export STUB_NGINX_T=fail
    run "$SCRIPT" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx -t refused the configuration with Coraza; rolled back"* ]]
    assert_no_links
    [ "$(reloads)" -eq 0 ]
}

@test "enabled probes only once the workers of before the reload stop taking requests" {
    export STUB_RELOAD_LAG=2 KEEL_CORAZA_TRIES=4
    run "$SCRIPT" enabled
    [ "$status" -eq 0 ]
    # the listing before the reload, two that still show the old workers,
    # one that shows only new ones, and only then the probe
    [ "$(grep -c -- "-xf nginx: worker process" "$STUB_LOG")" -eq 4 ]
    [ "$(grep -n -m1 keel-waf-probe "$STUB_LOG" | cut -d: -f1)" -gt \
      "$(grep -n -- "-xf nginx: worker process" "$STUB_LOG" | tail -1 | cut -d: -f1)" ]
}

@test "enabled probes anyway when old workers keep taking requests" {
    export STUB_RELOAD_LAG=99
    run "$SCRIPT" enabled
    [ "$status" -eq 0 ]
    assert_enabled_links
}

@test "enabled rolls back when the reload fails" {
    export STUB_NGINX_RELOAD=fail
    run "$SCRIPT" enabled
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx -s reload failed; rolled back"* ]]
    assert_no_links
}

@test "enabled rolls back when a rule Coraza refuses killed every worker" {
    export STUB_CORAZA_KILLS_WORKERS=1
    run "$SCRIPT" enabled
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no nginx worker is running"* ]]
    [[ "$output" == *"coraza-nginx#139"* ]]
    [[ "$output" == *"rolled back"* ]]
    assert_no_links
    # once to turn it on, once to take it back
    [ "$(reloads)" -eq 2 ]
}

@test "enabled rolls back when the workers live but the probe is not blocked" {
    export STUB_PROBE=200
    run "$SCRIPT" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"the probe got 200, not 403"* ]]
    [[ "$output" == *"rolled back"* ]]
    assert_no_links
}

@test "enabled keeps a module link that was there before when it rolls back" {
    ln -s "$KEEL_CORAZA_MODULE_CONF" "$MODULE_LINK"
    export STUB_PROBE=200
    run "$SCRIPT" enabled
    [ "$status" -eq 1 ]
    [ "$(readlink "$MODULE_LINK")" = "$KEEL_CORAZA_MODULE_CONF" ]
    [ ! -L "$WAF_LINK" ]
}

@test "enabled says so when nginx does not answer even after the rollback" {
    export STUB_PROBE=200 STUB_HEALTH=000
    run "$SCRIPT" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx does not answer /keel-health after the rollback"* ]]
    assert_no_links
}

@test "enabled refuses a file of the operator's where a link goes" {
    echo "coraza on;" > "$WAF_LINK"
    run "$SCRIPT" enabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"$WAF_LINK is not a link"* ]]
    [ "$(cat "$WAF_LINK")" = "coraza on;" ]
    [ ! -L "$MODULE_LINK" ]
    [ ! -s "$STUB_LOG" ]
}

# ------------------------------------------------------------ disabled

@test "disabled removes both links, reloads, and checks the probe passes" {
    link_enabled
    run "$SCRIPT" disabled
    echo "$output"
    [ "$status" -eq 0 ]
    assert_no_links
    [ "$(reloads)" -eq 1 ]
    [[ "$output" == *"coraza: disabled: the module is not loaded"* ]]
}

@test "disabled when already disabled changes nothing" {
    run "$SCRIPT" disabled
    [ "$status" -eq 0 ]
    [ "$output" = "coraza: unchanged (disabled)" ]
    [ ! -s "$STUB_LOG" ]
}

@test "disabled removes a module link left without the WAF's" {
    ln -s "$KEEL_CORAZA_MODULE_CONF" "$MODULE_LINK"
    run "$SCRIPT" disabled
    [ "$status" -eq 0 ]
    assert_no_links
}

@test "disabled puts the links back when nginx -t refuses the result" {
    link_enabled
    export STUB_NGINX_T=fail
    run "$SCRIPT" disabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx -t refuses the configuration without Coraza"* ]]
    assert_enabled_links
    [ "$(reloads)" -eq 0 ]
}

@test "disabled with nginx stopped only removes the links" {
    link_enabled
    nginx_stopped
    run "$SCRIPT" disabled
    [ "$status" -eq 0 ]
    assert_no_links
    [ "$(reloads)" -eq 0 ]
    [[ "$output" == *"nginx is not running"* ]]
}

@test "disabled fails when nginx does not answer afterwards" {
    link_enabled
    export STUB_HEALTH=000
    run "$SCRIPT" disabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx does not answer /keel-health"* ]]
    assert_no_links
}

@test "disabled says so when the reload fails, the links gone" {
    link_enabled
    export STUB_NGINX_RELOAD=fail
    run "$SCRIPT" disabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx -s reload failed"* ]]
    assert_no_links
}

@test "disabled refuses a file of the operator's where a link goes" {
    echo "load_module x;" > "$MODULE_LINK"
    run "$SCRIPT" disabled
    [ "$status" -eq 1 ]
    [[ "$output" == *"$MODULE_LINK is not a link"* ]]
    [ "$(cat "$MODULE_LINK")" = "load_module x;" ]
}

# ------------------------------------------------------------ recheck
# what the dpkg trigger of keel-overlay-coraza runs when the rule set, the
# module or the engine is upgraded under an enabled Coraza

@test "recheck with Coraza disabled does nothing" {
    run "$SCRIPT" recheck
    [ "$status" -eq 0 ]
    [ "$output" = "coraza: nothing to recheck (disabled)" ]
    [ ! -s "$STUB_LOG" ]
}

@test "recheck with nginx stopped does nothing" {
    link_enabled
    nginx_stopped
    run "$SCRIPT" recheck
    [ "$status" -eq 0 ]
    [[ "$output" == *"nginx is not running"* ]]
    assert_enabled_links
    [ ! -s "$STUB_LOG" ]
}

@test "recheck reloads and keeps Coraza when the probe still gets 403" {
    link_enabled
    run "$SCRIPT" recheck
    [ "$status" -eq 0 ]
    [ "$output" = "coraza: rechecked: the probe got 403 and /keel-health 204" ]
    [ "$(reloads)" -eq 1 ]
    assert_enabled_links
}

@test "recheck turns Coraza off when the new rules kill every worker" {
    link_enabled
    export STUB_CORAZA_KILLS_WORKERS=1
    run "$SCRIPT" recheck
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no nginx worker is running"* ]]
    [[ "$output" == *"rolled back, Coraza is off"* ]]
    assert_no_links
    [ "$(reloads)" -eq 2 ]
}

@test "recheck turns Coraza off when nginx -t refuses the new files" {
    link_enabled
    export STUB_NGINX_T=fail
    run "$SCRIPT" recheck
    [ "$status" -eq 1 ]
    assert_no_links
    [ "$(reloads)" -eq 0 ]
}
