#!/bin/bash
# Pure helpers of bin/keel-version-files (decision 0004: logic apart from
# effect). Nothing here writes a file, runs a command, reads the clock or
# looks at anything but its arguments. Sourced by bin/keel-version-files
# and by tests/version-files.bats.
#
# What the two identity files are, and why there are two (decision 0014):
#
#   /etc/turnkey_version  the compatibility contract. Its name and its
#                         grammar, turnkey-<app>-<version>-<codename>-<arch>,
#                         are an interface: the sysversion library, the
#                         turnkey-version command, inithooks' 29tagid and
#                         keel's own inspect all parse it, and every one of
#                         those parsers is prefix sensitive. It therefore
#                         always begins with "turnkey-", whatever the
#                         product's changelog calls the release package.
#   /etc/keel_version     what this appliance says it is. Same grammar,
#                         "keel-" prefix, and the file everything Keel
#                         presents to an operator reads first.
#
# The input is the string fab's turnkey-version.py builds from the first
# line of the product changelog, which is why the prefix cannot be trusted:
# a repository that renames its release package (keel-core-19.0, as
# keel-core did on 2026-09-27) would otherwise write an /etc/turnkey_version
# that none of those parsers accepts.

# Which prefixes name a product rather than an appliance.
# shellcheck disable=SC2034  # KVF_TURNKEY_PREFIX and _KEEL_PREFIX are read by the caller
KVF_PREFIXES="turnkey keel"
KVF_TURNKEY_PREFIX=turnkey
KVF_KEEL_PREFIX=keel

# kvf_has_prefix TEXT
# TEXT begins with one of the product prefixes and its hyphen. The one rule
# both helpers below apply: kvf_app_version removes such a prefix, and
# kvf_is_app_version refuses a string that still carries one.
kvf_has_prefix() {
    local text=${1-} prefix
    for prefix in $KVF_PREFIXES; do
        if [ "${text#"$prefix"-}" != "$text" ]; then
            return 0
        fi
    done
    return 1
}

# kvf_app_version RELEASE_NAME
# The <app>-<version>-<codename>-<arch> part of a release version string,
# with at most one product prefix removed: turnkey-wordpress-19.0-trixie-amd64
# and keel-core-19.0-trixie-amd64 both lose their first field, a name with
# neither prefix is returned whole, and an app whose own name starts with
# the other product's name keeps it.
kvf_app_version() {
    local text=${1-}
    if kvf_has_prefix "$text"; then
        text=${text#*-}
    fi
    printf '%s\n' "$text"
}

# kvf_is_app_version TEXT
# TEXT carries the four fields an appliance identity needs:
# <app>-<version>-<codename>-<arch>, app lower case and possibly
# hyphenated, version starting with a digit so a release tag such as
# 19.0rc is part of it, codename and architecture one field each. A string
# that still carries a product prefix fails, because "turnkey" would then
# be read as the app: the prefix comes off first, with kvf_app_version.
kvf_is_app_version() {
    local text=${1-}
    if kvf_has_prefix "$text"; then
        return 1
    fi
    [[ $text =~ ^[a-z0-9][a-z0-9.+-]*-[0-9][^-]*-[a-z][a-z0-9]*-[a-z0-9]+$ ]]
}

# kvf_version_string PREFIX APP_VERSION
# One identity string: the product prefix and the four fields.
kvf_version_string() {
    printf '%s-%s\n' "${1-}" "${2-}"
}
