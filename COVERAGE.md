# Test coverage baseline

Measured on 2026-09-24 against upstream 19.x (b60dd23), following the
project decision 0003 (90 percent floor per repository, 95 percent for every
file our changes touch).

## Baseline: 0 percent, nothing measured

This repository has no test suite and no coverage tool wired up, so nothing
is measured. Line counts are lines that are neither blank nor comment.

Inventory command (shebang or extension decides the kind):

    find . -type f -not -path './.git/*' -not -path './debian/*' \
      | while read f; do h=$(head -1 "$f"); case "$f$h" in *.py*|*python*) k=py;; \
      *sh*) k=sh;; *) continue;; esac; echo "$k $(grep -cvE '^\s*(#|$)' "$f") $f"; done

| Group | Files | Lines | Measured |
|-------|-------|-------|----------|
| conf/turnkey.d (core conf scripts) | 33 | 409 | 0 percent, no test |
| conf/ other (per-stack conf scripts, bootstrap_apt 319) | 38 | 1027 | 0 percent, no test |
| overlays/*/usr/lib/inithooks/firstboot.d (first-boot hooks) | 14 | 106 | 0 percent, no test |
| overlays/*/usr/lib/inithooks/bin (first-boot Python) | 6 | 412 | 0 percent, no test |
| overlays/turnkey.d (systemd-chroot, gh_releases, lsof, etckeeper, bashlib) | 8 | 404 | 0 percent, no test |
| overlays/ other bin and scripts | 18 | 450 | 0 percent, no test |
| overlays/ninjux/usr/local/bin/quicktile.py (third party) | 1 | 905 | 0 percent, no test |

Total: 107 shell files (2304 lines) and 11 Python files (1409 lines), 118
files, 3713 lines, 0 percent measured.

## Our branches and the 95 percent bar

| Branch | File touched | Automated test |
|--------|--------------|----------------|
| fix/postfix-local-fatal | conf/turnkey.d/postfix-local (20 lines) | None. The fix to `fatal()` and the actionable port 25 error were verified by hand on a VM. The file is at 0 percent, below the 95 percent bar. |

## Plan to reach 90 percent per file

Method for shell: `tests/` with shell test files that run each script
against a scratch root, `PATH` pointing at stub commands (`apt-get`,
`systemctl`, `ss`, `sed`, `update-rc.d`, `a2enmod`, `mysql`, `psql`) that
record arguments. Coverage counted from `bash -x` traces (kcov when the
decision 0003 open item settles). Python: `coverage run --branch` with
`pytest`, `fail_under` committed in `pyproject.toml`. Every `fatal` and
every exit code gets a test. Hosts in fixtures are IPv6 (`2001:db8::/32`).

Priority order (size: small under 30 lines of test, medium under 150,
large above):

1. `conf/turnkey.d/postfix-local` (small). Target 95 percent. Tests:
   `HOSTNAME` unset exits 1 with the message; port 25 busy (stub `ss`
   printing a `[::]:25` listener) exits 1 with the actionable text; happy
   path writes `main.cf` and enables `postfix@-.service`.
2. First-boot hooks, `overlays/*/usr/lib/inithooks/firstboot.d/*` (14
   files, each small): 35adminer-mysqlpass, 32userpass, 35pgsqlpass,
   20regen-rails-secrets (rails and rails-pgsql), 35samba-container,
   35samba-sudoadmin, 20regen-sid, 35timezone, 16tomcat-sslcert, 40tomcat,
   92etckeeper, 35vcs-passwd, 40web2py. One test file per hook: `_TURNKEY_INIT`
   short circuit, missing config, happy path with stubs.
3. First-boot Python, `overlays/*/usr/lib/inithooks/bin/*.py`:
   mysqlconf.py 126 lines (medium), pgsqlconf.py 87 (medium), setpass.py 55
   (small), tomcat.py 51 (small), sambapass.py 48 (small), web2py.py 45
   (small). Mock `subprocess` and the dialog wrapper; cover every
   argument error and non-zero exit.
4. `conf/turnkey.d/*` remaining 32 scripts (small each, 389 lines): the
   larger ones first, webmin-fw 67, motd 46, webmin-conf-logging 38,
   zz-ssl-ciphers 36, cronapt 30, locale 27, hostname 22; then the one to
   fifteen line scripts, one invocation test each.
5. `overlays/turnkey.d` (medium each): systemd-chroot `service` 126 and
   `systemctl` 114 (case tables, a test per verb), gh_releases 99 (stub
   `curl` with recorded JSON), lsof-restart-services 31, tkl-bashlib
   init.sh 22, etckeeper hooks (small).
6. `conf/` per-stack scripts: bootstrap_apt 319 (large, split the apt
   source generation into functions), rails 98 and rails-pgsql 96
   (medium), php 51, tomcat 50, apache-credit 48, samba-dav 48 (medium),
   the other 31 (small).
7. `overlays/` other scripts (small each): turnkey-composer 56,
   tkl-composer-squash-vendor 65, apt-packages-origin 60 (Python),
   turnkey-mysql-install-perf-info-schemas 54, cert-staple.sh 42,
   turnkey-php 37, svnserve 37, 45sound 27, logout 22 and the one to seven
   line wrappers.
8. `overlays/ninjux/usr/local/bin/quicktile.py` (large, 905 lines): third
   party code vendored into the overlay. Proposal to the maintainer: mark
   it as vendored and exclude it from the floor, or replace it with the
   packaged version, rather than write tests for upstream code.

The repository total is remeasured after each step and replaces the
0 percent above.
