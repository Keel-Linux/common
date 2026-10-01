#!/usr/bin/env bats
# Tests for packages/anubis/signing-key, which makes the key Anubis signs
# its challenge cookies with, once, when the Anubis overlay is first turned
# on (decision 0041, step 6; the secret anubis_signing_key of the overlay
# manifest). keel-overlay-anubis-key.service runs it before
# anubis@keel.service starts; the real unit is tests/overlay-web.bats'.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../packages/anubis/signing-key"
    KEY="$BATS_TEST_TMPDIR/etc/anubis/keel.key"
    mkdir -p "${KEY%/*}"
}

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
