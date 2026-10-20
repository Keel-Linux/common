#!/usr/bin/env bats
# Tests for packages/syncthing/health, the check the overlay manifest names
# (handbook decision 0050, amendment item 4: the REST API listens on the
# loopback, behind an API key). The Syncthing REST API is a stub from
# tests/stubs-syncthing that answers /rest/system/ping with the API key of
# STUB_APIKEY, and 401 to any other key. The real Syncthing is
# tests/overlay-syncthing.bats'.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../packages/syncthing/health"
    CONFIG="$BATS_TEST_TMPDIR/config.xml"
    export KEEL_SYNCTHING_CONFIG="$CONFIG"
    export STUB_APIKEY="the-test-api-key"
    export STUB_PORT=$(( (RANDOM % 20000) + 20000 ))
    export KEEL_SYNCTHING_URL="http://127.0.0.1:$STUB_PORT/rest/system/ping"
    SERVER=""
}

teardown() {
    if [ -n "$SERVER" ]; then
        kill "$SERVER" 2>/dev/null || true
        wait "$SERVER" 2>/dev/null || true
    fi
}

# the stub REST API, up
server_up() {
    python3 "$TESTS_DIR/stubs-syncthing/httpserver.py" &
    SERVER=$!
    sleep 0.3
}

# a configuration file with the API key of its argument
config_with_key() {
    printf '<configuration version="30"><gui><apikey>%s</apikey></gui></configuration>' \
        "$1" > "$CONFIG"
}

@test "fails when the configuration is not there" {
    run "$SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot read"* ]]
}

@test "fails when the configuration has no API key" {
    printf '<configuration version="30"><gui></gui></configuration>' > "$CONFIG"

    run "$SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"no API key"* ]]
}

@test "fails when the API key is wrong" {
    server_up
    config_with_key "another-key"

    run "$SCRIPT"

    [ "$status" -eq 1 ]
}

@test "answers pong when the API key is right" {
    server_up
    config_with_key "$STUB_APIKEY"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$output" = "health: pong" ]
}

@test "answers pong when the configuration has the syncthing schema namespace" {
    server_up
    printf '<configuration xmlns="http://syncthing.net/schema/config/2" version="52"><gui><apikey>%s</apikey></gui></configuration>' \
        "$STUB_APIKEY" > "$CONFIG"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$output" = "health: pong" ]
}

@test "fails when nothing listens on the port" {
    config_with_key "$STUB_APIKEY"

    run "$SCRIPT"

    [ "$status" -eq 1 ]
}
