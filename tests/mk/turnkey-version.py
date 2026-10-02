#!/bin/sh
# Stub of fab's turnkey-version.py: prints the version string a build
# derives from the product changelog, taken from KEEL_TEST_RELEASE.
printf '%s\n' "$KEEL_TEST_RELEASE"
