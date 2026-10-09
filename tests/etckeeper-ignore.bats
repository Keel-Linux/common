#!/usr/bin/env bats
# Tests for packages/installer/etckeeper-ignore, which keeps private keys
# and secrets out of etckeeper's /etc/.git (Keel-Linux/common#49).
# keel-overlay-installer's postinst runs it at each configure.
#
# The scratch /etc is a real git repository, and the ignore rules are read
# back by git itself (check-ignore, ls-files, add --all as etckeeper's
# commit runs it). The global and system git configuration is set aside,
# so the excludes of the machine that runs the tests change nothing. The
# real etckeeper on a booted trixie container is tests/overlay-install.bats'.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../packages/installer/etckeeper-ignore"
    export KEEL_ETC_DIR="$BATS_TEST_TMPDIR/etc"
    export HOME="$BATS_TEST_TMPDIR/home"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    mkdir -p "$KEEL_ETC_DIR" "$HOME"
    ETC="$KEEL_ETC_DIR"
}

# the private files keel and the overlays write under /etc
PRIVATE=(
    wireguard/wg0.key
    wireguard/wg1.key
    mysql/keel-tls/server.key
    etcd/keel/member.key
    etcd/keel/root.key
    etcd/keel/admin.key
    keel/secrets/root_password
    keel/secrets/cloud_api_key
    ssl/private/cert.pem
    ssl/private/cert.key
    ssl/private/ssl-cert-snakeoil.key
    ssh/ssh_host_ed25519_key
    ssh/ssh_host_rsa_key
    ssh/ssh_host_ecdsa_key
    crowdsec/local_api_credentials.yaml
    crowdsec/online_api_credentials.yaml
    crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local
    anubis/keel.key
    anubis/keel.key.from-primary
)

# public files beside them, which etckeeper keeps tracking
PUBLIC=(
    hosts
    wireguard/wg0.conf
    mysql/keel-tls/ca.pem
    mysql/keel-tls/server.pem
    mysql/keel-tls/crl.pem
    etcd/keel/ca.crt
    etcd/keel/member.crt
    etcd/keel/crl.pem
    keel/instance.yaml
    keel/monitor.json
    ssh/ssh_host_ed25519_key.pub
    ssh/sshd_config
    crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
    anubis/keel.env
)

# put FILE... in the scratch /etc, each holding its own name
write_files() {
    local file
    for file in "$@"; do
        mkdir -p "$ETC/$(dirname "$file")"
        printf '%s\n' "$file" > "$ETC/$file"
    done
}

# an /etc that etckeeper initialised and committed, with its managed
# section in .gitignore, every file of PRIVATE and PUBLIC tracked
etckeeper_repo() {
    write_files "${PRIVATE[@]}" "${PUBLIC[@]}"
    printf '%s\n' \
        "# begin section managed by etckeeper (do not edit this section by hand)" \
        "*.dpkg-*" \
        "# end section managed by etckeeper" \
        "inithooks.conf" > "$ETC/.gitignore"
    git -C "$ETC" init -q
    git -C "$ETC" add --all
    git -C "$ETC" -c user.name=etckeeper -c user.email=root@localhost \
        commit -q -m "initial commit"
}

tracked() {
    git -C "$ETC" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

block_count() {
    grep -c '^# begin keel-overlay-installer' "$ETC/.gitignore"
}

# ------------------------------------------------- the ignore list

@test "an /etc with no .gitignore gets the list, and git ignores every private file" {
    write_files "${PRIVATE[@]}" "${PUBLIC[@]}"
    git -C "$ETC" init -q

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$(block_count)" -eq 1 ]
    local file
    for file in "${PRIVATE[@]}"; do
        git -C "$ETC" check-ignore -q -- "$file" || {
            echo "not ignored: $file"
            return 1
        }
    done
}

@test "the public files beside the keys are not ignored" {
    write_files "${PRIVATE[@]}" "${PUBLIC[@]}"
    git -C "$ETC" init -q

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    local file
    for file in "${PUBLIC[@]}"; do
        if git -C "$ETC" check-ignore -q -- "$file"; then
            echo "ignored: $file"
            return 1
        fi
    done
}

@test "etckeeper's section and the other lines stay, and a second run adds no second list" {
    etckeeper_repo
    before="$(cat "$ETC/.gitignore")"

    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run "$SCRIPT"
    [ "$status" -eq 0 ]

    [ "$(block_count)" -eq 1 ]
    [ "$(head -4 "$ETC/.gitignore")" = "$before" ]
}

@test "an older list is replaced by the current one" {
    write_files "${PRIVATE[@]}"
    printf '%s\n' "keep-me" \
        "# begin keel-overlay-installer: an older list" \
        "/old/*.key" \
        "# end keel-overlay-installer" \
        "keep-me-too" > "$ETC/.gitignore"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$(block_count)" -eq 1 ]
    run grep -c '^/old/\*\.key$' "$ETC/.gitignore"
    [ "$output" = 0 ]
    grep -qx keep-me "$ETC/.gitignore"
    grep -qx keep-me-too "$ETC/.gitignore"
    grep -qx '/wireguard/\*.key' "$ETC/.gitignore"
}

@test "the file keeps its mode" {
    : > "$ETC/.gitignore"
    chmod 0640 "$ETC/.gitignore"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$ETC/.gitignore")" = 640 ]
}

@test "a new .gitignore is 0644, as etckeeper makes its own" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$ETC/.gitignore")" = 644 ]
}

@test "with no /etc/.git, the list is written and nothing else is done" {
    write_files "${PRIVATE[@]}"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$(block_count)" -eq 1 ]
    [ -z "$output" ]
    [ ! -e "$ETC/.git" ]
}

# ------------------------------------------------- keys already tracked

@test "tracked keys leave the index in a new commit, and stay on disk" {
    etckeeper_repo
    old="$(git -C "$ETC" rev-parse HEAD)"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$(git -C "$ETC" rev-parse HEAD~1)" = "$old" ]
    local file
    for file in "${PRIVATE[@]}"; do
        if tracked "$file"; then
            echo "still tracked: $file"
            return 1
        fi
        [ -f "$ETC/$file" ]
    done
    git -C "$ETC" log -1 --format=%s | grep -q 'Keel-Linux/common#49'
    [ "$(git -C "$ETC" log -1 --format='%an <%ae>')" = "keel-overlay-installer <root@localhost>" ]
}

@test "the public files stay tracked" {
    etckeeper_repo

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    local file
    for file in "${PUBLIC[@]}"; do
        tracked "$file" || {
            echo "not tracked: $file"
            return 1
        }
    done
}

@test "the history is not rewritten: the old commit still holds the keys" {
    etckeeper_repo
    old="$(git -C "$ETC" rev-parse HEAD)"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    git -C "$ETC" cat-file -e "$old:wireguard/wg0.key"
    git -C "$ETC" cat-file -e "$old:mysql/keel-tls/server.key"
    git -C "$ETC" merge-base --is-ancestor "$old" HEAD
}

@test "the operator is told which files left the index, and to rotate them" {
    etckeeper_repo

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"wireguard/wg0.key"* ]]
    [[ "$output" == *"mysql/keel-tls/server.key"* ]]
    [[ "$output" == *"history"* ]]
    [[ "$output" == *"rotate"* ]]
}

@test "the commit holds the list and the removals, and no other change" {
    etckeeper_repo
    printf 'changed\n' >> "$ETC/hosts"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    run git -C "$ETC" diff --name-only HEAD~1 HEAD
    [[ "$output" == *".gitignore"* ]]
    [[ "$output" == *"wireguard/wg0.key"* ]]
    [[ "$output" != *"hosts"* ]]
    run git -C "$ETC" diff --name-only
    [ "$output" = hosts ]
}

@test "the committer's identity of the environment wins" {
    etckeeper_repo
    export GIT_AUTHOR_NAME=operator GIT_AUTHOR_EMAIL=operator@example.org

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$(git -C "$ETC" log -1 --format='%an <%ae>')" = "operator <operator@example.org>" ]
}

@test "with no key tracked, no commit is made" {
    write_files "${PUBLIC[@]}"
    git -C "$ETC" init -q
    git -C "$ETC" add --all
    git -C "$ETC" -c user.name=t -c user.email=t@t commit -q -m first
    old="$(git -C "$ETC" rev-parse HEAD)"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$(git -C "$ETC" rev-parse HEAD)" = "$old" ]
    [ -z "$output" ]
}

@test "a key written later is not taken by etckeeper's add --all" {
    etckeeper_repo
    run "$SCRIPT"
    [ "$status" -eq 0 ]

    write_files wireguard/wg2.key etcd/keel/client.key ssl/private/new.pem
    git -C "$ETC" add --all

    run git -C "$ETC" diff --cached --name-only
    [ -z "$output" ]
}

@test "a failed removal fails the run and commits nothing" {
    etckeeper_repo
    old="$(git -C "$ETC" rev-parse HEAD)"
    : > "$ETC/.git/index.lock"

    run "$SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"could not remove"* ]]
    [ "$(git -C "$ETC" rev-parse HEAD)" = "$old" ]
}

@test "a refused commit fails the run, and the operator is told" {
    etckeeper_repo
    old="$(git -C "$ETC" rev-parse HEAD)"
    printf '#!/bin/sh\nexit 1\n' > "$ETC/.git/hooks/pre-commit"
    chmod 0755 "$ETC/.git/hooks/pre-commit"

    run "$SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *"could not commit"* ]]
    [ "$(git -C "$ETC" rev-parse HEAD)" = "$old" ]
}

@test "etckeeper's pre-commit hook runs: the commit is not made with --no-verify" {
    etckeeper_repo
    printf '#!/bin/sh\ntouch "%s"\n' "$BATS_TEST_TMPDIR/hook-ran" > "$ETC/.git/hooks/pre-commit"
    chmod 0755 "$ETC/.git/hooks/pre-commit"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ -e "$BATS_TEST_TMPDIR/hook-ran" ]
}
