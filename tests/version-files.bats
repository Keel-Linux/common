#!/usr/bin/env bats
# Unit tests of lib/version-files.sh and bin/keel-version-files: the two
# identity files an image carries, /etc/turnkey_version (the interface we
# honour) and /etc/keel_version (what we say we are), decision 0014.
#
# Nothing here needs root, a chroot or a build: the script is given a
# version string and a directory, and writes two files into it.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    LIB="$ROOT/lib/version-files.sh"
    SCRIPT="$ROOT/bin/keel-version-files"
    load ../lib/version-files.sh
    SCRATCH="$BATS_TEST_TMPDIR/scratch"
    mkdir -p "$SCRATCH"
}

# the app part of a release version string

@test "app_version: the turnkey- prefix of a changelog name is dropped" {
    run kvf_app_version turnkey-wordpress-19.0-trixie-amd64
    [ "$status" -eq 0 ]
    [ "$output" = wordpress-19.0-trixie-amd64 ]
}

@test "app_version: the keel- prefix of a changelog name is dropped" {
    run kvf_app_version keel-core-19.0-trixie-amd64
    [ "$status" -eq 0 ]
    [ "$output" = core-19.0-trixie-amd64 ]
}

@test "app_version: a name with neither prefix is kept whole" {
    run kvf_app_version core-19.0-trixie-amd64
    [ "$status" -eq 0 ]
    [ "$output" = core-19.0-trixie-amd64 ]
}

@test "app_version: only one prefix is dropped, never two" {
    run kvf_app_version keel-turnkey-core-19.0-trixie-amd64
    [ "$output" = turnkey-core-19.0-trixie-amd64 ]
}

@test "app_version: an app name that begins with the other prefix survives" {
    run kvf_app_version turnkey-keelson-19.0-trixie-amd64
    [ "$output" = keelson-19.0-trixie-amd64 ]
}

@test "app_version: an empty string stays empty" {
    run kvf_app_version ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "app_version: no argument is the same as an empty string" {
    run kvf_app_version
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# the one prefix rule both helpers apply

@test "has_prefix: each product prefix followed by a hyphen" {
    kvf_has_prefix turnkey-core-19.0-trixie-amd64
    kvf_has_prefix keel-core-19.0-trixie-amd64
}

@test "has_prefix: a prefix without its hyphen is not one" {
    run kvf_has_prefix keelson-19.0-trixie-amd64
    [ "$status" -eq 1 ]
    run kvf_has_prefix turnkey
    [ "$status" -eq 1 ]
}

@test "has_prefix: an empty string and no argument have none" {
    run kvf_has_prefix ""
    [ "$status" -eq 1 ]
    run kvf_has_prefix
    [ "$status" -eq 1 ]
}

# the grammar of the four fields

@test "is_app_version: the four fields of an appliance" {
    run kvf_is_app_version core-19.0-trixie-amd64
    [ "$status" -eq 0 ]
}

@test "is_app_version: an app name with hyphens keeps them" {
    run kvf_is_app_version nginx-php-fastcgi-19.0-trixie-amd64
    [ "$status" -eq 0 ]
}

@test "is_app_version: a release tag is part of the version field" {
    run kvf_is_app_version core-19.0rc-trixie-amd64
    [ "$status" -eq 0 ]
}

@test "is_app_version: another architecture" {
    run kvf_is_app_version core-19.0-trixie-arm64
    [ "$status" -eq 0 ]
}

@test "is_app_version: a string missing the architecture is refused" {
    run kvf_is_app_version core-19.0-trixie
    [ "$status" -eq 1 ]
}

@test "is_app_version: a version that does not start with a digit is refused" {
    run kvf_is_app_version core-nineteen-trixie-amd64
    [ "$status" -eq 1 ]
}

@test "is_app_version: upper case is refused" {
    run kvf_is_app_version Core-19.0-trixie-amd64
    [ "$status" -eq 1 ]
}

@test "is_app_version: an empty string is refused" {
    run kvf_is_app_version ""
    [ "$status" -eq 1 ]
}

@test "is_app_version: no argument is refused" {
    run kvf_is_app_version
    [ "$status" -eq 1 ]
}

@test "is_app_version: a prefixed string is refused, the prefix goes first" {
    run kvf_is_app_version turnkey-core-19.0-trixie-amd64
    [ "$status" -eq 1 ]
}

# the two strings

@test "version_string: the compatibility string and the Keel string" {
    run kvf_version_string turnkey core-19.0-trixie-amd64
    [ "$output" = turnkey-core-19.0-trixie-amd64 ]
    run kvf_version_string keel core-19.0-trixie-amd64
    [ "$output" = keel-core-19.0-trixie-amd64 ]
}

# the script

@test "script: a turnkey changelog name writes both files" {
    run "$SCRIPT" turnkey-wordpress-19.0-trixie-amd64 "$SCRATCH"
    [ "$status" -eq 0 ]
    [ "$(cat "$SCRATCH/etc/turnkey_version")" = turnkey-wordpress-19.0-trixie-amd64 ]
    [ "$(cat "$SCRATCH/etc/keel_version")" = keel-wordpress-19.0-trixie-amd64 ]
}

@test "script: a keel changelog name still writes the compatibility file" {
    # The case that motivated the check: keel-core's changelog was renamed
    # to keel-core-19.0, and /etc/turnkey_version is parsed by prefix.
    run "$SCRIPT" keel-core-19.0-trixie-amd64 "$SCRATCH"
    [ "$status" -eq 0 ]
    [ "$(cat "$SCRATCH/etc/turnkey_version")" = turnkey-core-19.0-trixie-amd64 ]
    [ "$(cat "$SCRATCH/etc/keel_version")" = keel-core-19.0-trixie-amd64 ]
}

@test "script: the two files differ in the prefix and nothing else" {
    "$SCRIPT" keel-nginx-php-fastcgi-19.0-trixie-amd64 "$SCRATCH"
    turnkey=$(cat "$SCRATCH/etc/turnkey_version")
    keel=$(cat "$SCRATCH/etc/keel_version")
    [ "${turnkey#turnkey-}" = "${keel#keel-}" ]
}

@test "script: etc is created when the tree does not have it yet" {
    [ ! -d "$SCRATCH/etc" ]
    run "$SCRIPT" turnkey-core-19.0-trixie-amd64 "$SCRATCH"
    [ "$status" -eq 0 ]
    [ -d "$SCRATCH/etc" ]
}

@test "script: each file is one line, world readable" {
    "$SCRIPT" turnkey-core-19.0-trixie-amd64 "$SCRATCH"
    [ "$(wc -l < "$SCRATCH/etc/turnkey_version")" -eq 1 ]
    [ "$(wc -l < "$SCRATCH/etc/keel_version")" -eq 1 ]
    [ "$(stat -c %a "$SCRATCH/etc/turnkey_version")" = 644 ]
    [ "$(stat -c %a "$SCRATCH/etc/keel_version")" = 644 ]
}

@test "script: an existing pair is replaced, not appended to" {
    mkdir -p "$SCRATCH/etc"
    printf 'turnkey-core-18.0-bookworm-amd64\n' > "$SCRATCH/etc/turnkey_version"
    printf 'keel-core-18.0-bookworm-amd64\n' > "$SCRATCH/etc/keel_version"
    "$SCRIPT" turnkey-core-19.0-trixie-amd64 "$SCRATCH"
    [ "$(cat "$SCRATCH/etc/turnkey_version")" = turnkey-core-19.0-trixie-amd64 ]
    [ "$(wc -l < "$SCRATCH/etc/turnkey_version")" -eq 1 ]
}

@test "script: a version string it cannot name is refused and nothing is written" {
    run "$SCRIPT" not-a-version "$SCRATCH"
    [ "$status" -eq 1 ]
    [[ $output == *"not-a-version"* ]]
    [[ $output == *"app-version-codename-architecture"* ]]
    [ ! -e "$SCRATCH/etc/turnkey_version" ]
    [ ! -e "$SCRATCH/etc/keel_version" ]
}

@test "script: an empty version string is refused" {
    run "$SCRIPT" "" "$SCRATCH"
    [ "$status" -eq 1 ]
}

@test "script: too few arguments print the usage and fail" {
    run "$SCRIPT" turnkey-core-19.0-trixie-amd64
    [ "$status" -eq 1 ]
    [[ $output == *"usage: keel-version-files"* ]]
}

@test "script: too many arguments print the usage and fail" {
    run "$SCRIPT" turnkey-core-19.0-trixie-amd64 "$SCRATCH" extra
    [ "$status" -eq 1 ]
    [[ $output == *"usage: keel-version-files"* ]]
}

@test "script: a hyphenated release tag is refused, and the usage says why" {
    run "$SCRIPT" turnkey-core-19.0-rc1-trixie-amd64 "$SCRATCH"
    [ "$status" -eq 1 ]
    run "$SCRIPT" -h
    [[ $output == *"VERSION_TAG"* ]]
    [[ $output == *"no hyphen"* ]]
}

@test "script: -h prints the usage and succeeds" {
    run "$SCRIPT" -h
    [ "$status" -eq 0 ]
    [[ $output == *"usage: keel-version-files"* ]]
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
}

@test "script: a root that is not a directory is refused" {
    run "$SCRIPT" turnkey-core-19.0-trixie-amd64 "$SCRATCH/absent"
    [ "$status" -eq 2 ]
    [[ $output == *"$SCRATCH/absent"* ]]
    [[ $output == *"not a directory"* ]]
}

@test "script: a tree it cannot write to is refused" {
    mkdir -p "$SCRATCH/etc"
    chmod 0500 "$SCRATCH/etc"
    run "$SCRIPT" turnkey-core-19.0-trixie-amd64 "$SCRATCH"
    chmod 0700 "$SCRATCH/etc"
    [ "$status" -eq 2 ]
    [[ $output == *"cannot write"* ]]
}

@test "script: the library it needs is named in the failure when it is gone" {
    copy="$BATS_TEST_TMPDIR/keel-version-files"
    cp "$SCRIPT" "$copy"
    run "$copy" turnkey-core-19.0-trixie-amd64 "$SCRATCH"
    [ "$status" -eq 3 ]
    [[ $output == *"version-files.sh"* ]]
}

# the library under the caller's own shell options (docs/traps.md, "A bats
# suite cannot see a library that kills its caller"): bats turns errexit
# off, the script that sources this library does not.

@test "library: sourced under set -euo pipefail, a refusal does not kill the caller" {
    cat > "$BATS_TEST_TMPDIR/caller" <<CALLER
#!/bin/bash
set -euo pipefail
. "$LIB"
if kvf_is_app_version "not-a-version"; then
    echo "accepted"
else
    echo "refused"
fi
kvf_app_version turnkey-core-19.0-trixie-amd64
CALLER
    chmod +x "$BATS_TEST_TMPDIR/caller"
    run "$BATS_TEST_TMPDIR/caller"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = refused ]
    [ "${lines[1]}" = core-19.0-trixie-amd64 ]
}
