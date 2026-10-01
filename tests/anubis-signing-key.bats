#!/usr/bin/env bats
# Tests for packages/anubis/signing-key, which makes the key Anubis signs
# its challenge cookies with, once, when the Anubis overlay is first turned
# on (decision 0041, step 6; the secret anubis_signing_key of the overlay
# manifest). keel-overlay-anubis-key.service runs it before
# anubis@keel.service starts; the real unit is tests/overlay-web.bats'.
#
# The instance spec is read with python3 and PyYAML, as keel reads it.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../packages/anubis/signing-key"
    KEY="$BATS_TEST_TMPDIR/etc/anubis/keel.key"
    mkdir -p "${KEY%/*}"
    export KEEL_SPEC="$BATS_TEST_TMPDIR/etc/keel/instance.yaml"
    export KEEL_ANUBIS_FROM_PRIMARY="$BATS_TEST_TMPDIR/etc/anubis/keel.key.from-primary"
    mkdir -p "${KEEL_SPEC%/*}"
}

# spec YAML: the instance spec this test's machine has
spec() {
    printf '%s\n' "version: 1" "$@" > "$KEEL_SPEC"
}

hex_key() {
    printf 'cd%.0s' $(seq 32)
}

# ------------------------------------------------- what the spec says

@test "links the key file the spec names, and makes none" {
    printf '%s\n' "$(hex_key)" > "$BATS_TEST_TMPDIR/primary.key"
    spec "secrets:" "  anubis_signing_key: {file: $BATS_TEST_TMPDIR/primary.key}"

    run "$SCRIPT" "$KEY"

    [ "$status" -eq 0 ]
    [ "$(readlink "$KEY")" = "$BATS_TEST_TMPDIR/primary.key" ]
    [ "$(cat "$KEY")" = "$(hex_key)" ]
    [ "$output" = "anubis: $KEY is the spec's $BATS_TEST_TMPDIR/primary.key" ]
}

@test "refuses, making no key, when the file the spec names is not there" {
    spec "secrets:" "  anubis_signing_key: {file: $BATS_TEST_TMPDIR/missing.key}"

    run "$SCRIPT" "$KEY"

    [ "$status" -eq 1 ]
    [[ "$output" == *"the spec names $BATS_TEST_TMPDIR/missing.key"* ]]
    [ ! -e "$KEY" ]
    [ ! -L "$KEY" ]
}

@test "a spec that names the key's own path makes it there" {
    spec "secrets:" "  anubis_signing_key: {file: $KEY}"
    run "$SCRIPT" "$KEY"
    [ "$status" -eq 0 ]
    [ ! -L "$KEY" ]
    [[ "$(cat "$KEY")" =~ ^[0-9a-f]{64}$ ]]
}

@test "generates when the spec says generate" {
    spec "secrets:" "  anubis_signing_key: {generate: true}"
    run "$SCRIPT" "$KEY"
    [ "$status" -eq 0 ]
    [[ "$(cat "$KEY")" =~ ^[0-9a-f]{64}$ ]]
}

@test "never generates on a database replica: the key is the primary's" {
    spec "database:" "  server:" "    role: replica"

    run "$SCRIPT" "$KEY"

    [ "$status" -eq 1 ]
    [[ "$output" == *"shared"* ]]
    [[ "$output" == *"primary"* ]]
    [ ! -e "$KEY" ]
}

@test "never generates where the from-primary marker is" {
    : > "$KEEL_ANUBIS_FROM_PRIMARY"

    run "$SCRIPT" "$KEY"

    [ "$status" -eq 1 ]
    [[ "$output" == *"$KEEL_ANUBIS_FROM_PRIMARY"* ]]
    [ ! -e "$KEY" ]
}

@test "a key that is there wins over the marker" {
    printf '%s\n' "$(hex_key)" > "$KEY"
    : > "$KEEL_ANUBIS_FROM_PRIMARY"
    run "$SCRIPT" "$KEY"
    [ "$status" -eq 0 ]
    [ "$(cat "$KEY")" = "$(hex_key)" ]
}

@test "replaces a dangling link left where the key goes" {
    ln -s "$BATS_TEST_TMPDIR/gone.key" "$KEY"
    run "$SCRIPT" "$KEY"
    [ "$status" -eq 0 ]
    [ ! -L "$KEY" ]
    [[ "$(cat "$KEY")" =~ ^[0-9a-f]{64}$ ]]
}

@test "refuses, making no key, when the spec cannot be read" {
    printf 'secrets: [unclosed\n' > "$KEEL_SPEC"

    run "$SCRIPT" "$KEY"

    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot read $KEEL_SPEC"* ]]
    [ ! -e "$KEY" ]
}

@test "refuses, making no key, when the spec is not a mapping" {
    printf -- '- a list\n' > "$KEEL_SPEC"
    run "$SCRIPT" "$KEY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a mapping"* ]]
    [ ! -e "$KEY" ]
}

@test "generates on a machine with no spec" {
    rm -f "$KEEL_SPEC"
    run "$SCRIPT" "$KEY"
    [ "$status" -eq 0 ]
    [[ "$(cat "$KEY")" =~ ^[0-9a-f]{64}$ ]]
}

# ------------------------------------------------- generating

@test "refuses to run without the key's path" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [ "$output" = "usage: signing-key FILE" ]
}

@test "writes a hex encoded 32-byte ed25519 seed, as Anubis reads it" {
    run "$SCRIPT" "$KEY"
    [ "$status" -eq 0 ]
    [[ "$(cat "$KEY")" =~ ^[0-9a-f]{64}$ ]]
    [ "$output" = "anubis: generated the signing key $KEY" ]
}

@test "the key is readable by its owner only" {
    run "$SCRIPT" "$KEY"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$KEY")" = 600 ]
}

@test "two keys are not the same" {
    "$SCRIPT" "$KEY"
    first="$(cat "$KEY")"
    rm "$KEY"
    "$SCRIPT" "$KEY"
    [ "$(cat "$KEY")" != "$first" ]
}

@test "leaves a key that is there, as a node of a set holds the primary's" {
    printf '%s\n' "$(printf 'ab%.0s' $(seq 32))" > "$KEY"
    chmod 0600 "$KEY"
    before="$(cat "$KEY")"

    run "$SCRIPT" "$KEY"

    [ "$status" -eq 0 ]
    [ "$(cat "$KEY")" = "$before" ]
    [ "$output" = "anubis: $KEY is there; left as it is" ]
}

@test "leaves no partial file when the random source fails" {
    KEEL_RANDOM="$BATS_TEST_TMPDIR/no-such-device" run "$SCRIPT" "$KEY"
    [ "$status" -ne 0 ]
    [ ! -e "$KEY" ]
    [ -z "$(find "${KEY%/*}" -mindepth 1)" ]
}

@test "refuses a source that does not give 32 bytes" {
    : > "$BATS_TEST_TMPDIR/short"
    KEEL_RANDOM="$BATS_TEST_TMPDIR/short" run "$SCRIPT" "$KEY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not 64 hex digits"* ]]
    [ ! -e "$KEY" ]
    [ -z "$(find "${KEY%/*}" -mindepth 1)" ]
}

@test "does not replace a key written meanwhile by someone else" {
    # the key appears between the check and the write: the link that
    # publishes the new key refuses to replace it
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nprintf other > "%s"\nexec /usr/bin/od "$@"\n' "$KEY" \
        > "$BATS_TEST_TMPDIR/bin/od"
    chmod 0755 "$BATS_TEST_TMPDIR/bin/od"

    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$SCRIPT" "$KEY"

    [ "$status" -eq 0 ]
    [ "$(cat "$KEY")" = other ]
    [[ "$output" == *"written meanwhile; left as it is"* ]]
    [ "$(find "${KEY%/*}" -mindepth 1 | wc -l)" -eq 1 ]
}
