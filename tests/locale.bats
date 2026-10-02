#!/usr/bin/env bats
# Tests for conf/turnkey.d/locale, against a scratch tree.
#
# /etc/default/locale is what pam_env gives a login, on the console and
# over SSH. It said LC_ALL=C and LC_CTYPE=C, so a login ran in an ASCII
# locale, and dialog (confconsole after login) drew its boxes with the
# VT100 line drawing set, which the LXC console shows as lqqqk and x (the
# maintainer's screenshot 027). LANG=C.UTF-8 alone is a locale that
# always exists (libc-bin ships /usr/lib/locale/C.utf8), is UTF-8, so the
# boxes are drawn with Unicode lines, and is overridden by nothing, so
# keel's locale.lang, which writes LANG, takes effect.
#
# localepurge, dpkg-reconfigure and debconf-set-selections are stubs that
# record their arguments in STUB_LOG.

bats_require_minimum_version 1.5.0

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SCRIPT="$TESTS_DIR/../conf/turnkey.d/locale"
    STUBS=$BATS_TEST_TMPDIR/stubs
    mkdir -p "$STUBS"
    export STUB_LOG=$BATS_TEST_TMPDIR/calls.log
    : > "$STUB_LOG"
    for name in localepurge dpkg-reconfigure debconf-set-selections; do
        printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\n' "$name" \
            > "$STUBS/$name"
        chmod +x "$STUBS/$name"
    done
    # the one fed on its standard input, which it records too
    echo 'cat >> "$STUB_LOG"' >> "$STUBS/debconf-set-selections"
    export PATH="$STUBS:$PATH"

    IMAGE=$BATS_TEST_TMPDIR/image
    mkdir -p "$IMAGE/etc/default"
    printf '# en_US.UTF-8 UTF-8\n# pt_BR.UTF-8 UTF-8\n' > "$IMAGE/etc/locale.gen"
    export LOCALE_FILE=$IMAGE/etc/default/locale
    export LOCALE_GEN=$IMAGE/etc/locale.gen
    export LOCALE_NOPURGE=$IMAGE/etc/locale.nopurge
    export WEBMIN_DIR=$IMAGE/usr/share/webmin
}

@test "a login gets a UTF-8 locale, never the ASCII C" {
    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$(cat "$LOCALE_FILE")" = 'LANG=C.UTF-8' ]
}

@test "dpkg-reconfigure locales writes LANG=C.UTF-8 back, not en_US" {
    # on a reconfigure the locales postinst runs update-locale with the
    # debconf default_environment_locale, over what the file says
    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'locales locales/default_environment_locale select C.UTF-8' \
        "$STUB_LOG"
    grep -qx 'locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8' \
        "$STUB_LOG"
}

@test "nothing overrides LANG, so a later locale.lang takes effect" {
    run "$SCRIPT"

    [ "$status" -eq 0 ]
    run grep -E '^(LC_ALL|LC_CTYPE|LANGUAGE)=' "$LOCALE_FILE"
    [ "$status" -eq 1 ]
}

@test "the locale it sets exists without being generated" {
    # libc-bin ships C.UTF-8 compiled, outside the locale archive that
    # locale-gen and localepurge manage
    [ -d /usr/lib/locale/C.utf8 ]
    run env -i LC_ALL=C.UTF-8 locale charmap
    [ "$status" -eq 0 ]
    [ "$output" = "UTF-8" ]
    [ -z "$(env -i LC_ALL=C.UTF-8 locale 2>&1 >/dev/null)" ]
}

@test "dialog draws its boxes with Unicode lines under it, not VT100's" {
    if ! command -v dialog >/dev/null || ! command -v script >/dev/null; then
        skip "dialog or script is not installed"
    fi
    for locale in C C.UTF-8; do
        LC_ALL=$locale TERM=linux timeout 5 script -qec \
            "dialog --msgbox x 5 10" /dev/null \
            > "$BATS_TEST_TMPDIR/$locale.out" < /dev/null || true
    done
    # the VT100 set is switched in with ESC ( 0 or SO, which is what the
    # old C locale drew; the UTF-8 locale draws U+250C and its kin instead
    grep -q $'\e(0\|\x0e' "$BATS_TEST_TMPDIR/C.out"
    grep -q $'┌' "$BATS_TEST_TMPDIR/C.UTF-8.out"
    ! grep -q $'\e(0\|\x0e' "$BATS_TEST_TMPDIR/C.UTF-8.out"
}

@test "en_US.UTF-8 is still generated and kept from localepurge" {
    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -qx 'en_US.UTF-8 UTF-8' "$LOCALE_GEN"
    grep -qx '# pt_BR.UTF-8 UTF-8' "$LOCALE_GEN"
    grep -qx 'en_US.UTF-8' "$LOCALE_NOPURGE"
    grep -qF 'dpkg-reconfigure locales' "$STUB_LOG"
    grep -qF 'localepurge' "$STUB_LOG"
    grep -qF 'debconf-set-selections' "$STUB_LOG"
}

@test "webmin's other languages are removed when webmin is there" {
    mkdir -p "$WEBMIN_DIR/help"
    touch "$WEBMIN_DIR/help/intro.de.html" "$WEBMIN_DIR/help/intro.html"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ ! -e "$WEBMIN_DIR/help/intro.de.html" ]
    [ -e "$WEBMIN_DIR/help/intro.html" ]
}
