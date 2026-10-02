#!/usr/bin/env bats
# Tests for conf/turnkey.d/webmin-theme and conf/turnkey.d/webmin-defmodule:
# Webmin shows the Keel Linux lockup, not TurnKey's, on its login page and
# in its menu, and opens on its own dashboard, not on the TKLBAM page that
# asks for a TurnKey Hub key.
#
# The lockups are the handbook's exports, copied as they are
# (Keel-Linux/handbook docs/brand/site/, 9be1093): the one for dark
# backgrounds goes on the navy menu, the one for light backgrounds on the
# white login card. Their digests are pinned here so that a redrawn or
# re-encoded file fails the test instead of shipping.

bats_require_minimum_version 1.5.0

OVERLAY_DIR="$BATS_TEST_DIRNAME/../overlays/turnkey.d/webmin/etc/webmin/authentic-theme"
DARK_SHA256=7dab21adaed6401d1ac5ec9aeac64198049e1b7f1f3247ed55a1a13977c186d8
LIGHT_SHA256=9095b31ad48322581c78c31293825dfcf6e012056f6ac6192e4ca5aa90e9a374

setup() {
    THEME_SCRIPT="$BATS_TEST_DIRNAME/../conf/turnkey.d/webmin-theme"
    DEFMODULE_SCRIPT="$BATS_TEST_DIRNAME/../conf/turnkey.d/webmin-defmodule"
    # /etc/webmin of an image the common overlay has been applied to
    export WEBMIN_CONF_DIR=$BATS_TEST_TMPDIR/etc/webmin
    mkdir -p "$WEBMIN_CONF_DIR"
    cp -R "$OVERLAY_DIR" "$WEBMIN_CONF_DIR/"
    printf 'lang=en\n' > "$WEBMIN_CONF_DIR/config"
    printf 'port=12321\n' > "$WEBMIN_CONF_DIR/miniserv.conf"
    unset WEBMIN_THEME
}

sha256() {
    sha256sum "$1" | cut -d' ' -f1
}

@test "the overlay ships the handbook's lockups and no TurnKey logo" {
    [ "$(sha256 "$OVERLAY_DIR/keel-lockup-horizontal-dark.png")" = "$DARK_SHA256" ]
    [ "$(sha256 "$OVERLAY_DIR/keel-lockup-horizontal-light.png")" = "$LIGHT_SHA256" ]
    run ! compgen -G "$OVERLAY_DIR/tkl-*"
}

@test "the menu shows the lockup for dark backgrounds" {
    run "$THEME_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(sha256 "$WEBMIN_CONF_DIR/authentic-theme/logo.png")" = "$DARK_SHA256" ]
}

@test "the login page shows the lockup for light backgrounds" {
    run "$THEME_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(sha256 "$WEBMIN_CONF_DIR/authentic-theme/logo_welcome.png")" = "$LIGHT_SHA256" ]
}

@test "the theme leaves only the two files the theme reads" {
    run "$THEME_SCRIPT"
    [ "$status" -eq 0 ]
    run ls "$WEBMIN_CONF_DIR/authentic-theme"
    [ "$output" = "logo.png
logo_welcome.png" ]
}

@test "authentic-theme is the theme, unless the build names another" {
    run "$THEME_SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'theme=authentic-theme' "$WEBMIN_CONF_DIR/config"
    grep -qx 'preroot=authentic-theme' "$WEBMIN_CONF_DIR/miniserv.conf"
}

@test "a theme named by the build is the one configured and branded" {
    mv "$WEBMIN_CONF_DIR/authentic-theme" "$WEBMIN_CONF_DIR/other-theme"
    WEBMIN_THEME=other-theme run "$THEME_SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'theme=other-theme' "$WEBMIN_CONF_DIR/config"
    [ "$(sha256 "$WEBMIN_CONF_DIR/other-theme/logo.png")" = "$DARK_SHA256" ]
}

@test "webmin opens on its dashboard, not on a module" {
    run "$DEFMODULE_SCRIPT"
    [ "$status" -eq 0 ]
    run ! grep -q '^gotomodule=' "$WEBMIN_CONF_DIR/config"
    grep -qx 'gotoone=0' "$WEBMIN_CONF_DIR/config"
    grep -qx 'nomoduleup=1' "$WEBMIN_CONF_DIR/config"
}

@test "a gotomodule already in the config is taken out" {
    printf 'gotomodule=tklbam\n' >> "$WEBMIN_CONF_DIR/config"
    run "$DEFMODULE_SCRIPT"
    [ "$status" -eq 0 ]
    run ! grep -q '^gotomodule=' "$WEBMIN_CONF_DIR/config"
    grep -qx 'lang=en' "$WEBMIN_CONF_DIR/config"
}
