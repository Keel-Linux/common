# Overlay packages

Every overlay of `common` is its own Debian source package here, one
directory each, with its own changelog and version, released on its own
(handbook decisions 0036, 0039 and 0041). The `.deb` is named
`keel-overlay-<name>` and ships the overlay manifest, which sits beside
`debian/` as `manifest.yaml` and is installed as
`/usr/share/keel/overlays/<name>.yaml` (docs/manifest-v1.md in the handbook).

| Directory | Package | Rests on | Units it owns |
| --- | --- | --- | --- |
| `installer/` | `keel-overlay-installer` | Keel's `inithooks` (>= 2.3.6+keel14), `confconsole` (>= 2.2.3+keel8), `keel` (>= 0.12.0) | none; its manifest names the first boot hooks the three ship |
| `wireguard/` | `keel-overlay-wireguard` | trixie's `wireguard-tools` 1.0.20210914 | none; the interface is the instance spec's |
| `etcd/` | `keel-overlay-etcd` | trixie's `etcd-server` 3.5.16 and its `etcd-client` (etcdctl, which keel asks etcd with over gRPC, keel#83), both bounded to that upstream release, `keel` (>= 0.22.0), whose gate its drop-in runs and whose etcd goes through etcdctl, and `keel-overlay-wireguard`, which its manifest `requires` | `etcd.service`, and its drop-in `keel-overlay-etcd.conf`: one member restarts at a time |
| `vip/` | `keel-overlay-vip` | `keel` (>= 0.21.0), whose `keel vip` the units run, and `keel-overlay-wireguard`, which its manifest `requires` | `keel-vip.service`, the VIP's root helper with etcd, which starts its unprivileged controller as the transient `keel-vip-control`; and `keel-vip-check.timer`, part of it |
| `crowdsec/` | `keel-overlay-crowdsec` | trixie's `crowdsec` 1.4.6-10 and `crowdsec-firewall-bouncer` 0.0.25 | `crowdsec.service`, `crowdsec-firewall-bouncer.service` |
| `nginx/` | `keel-overlay-nginx` | trixie's `nginx` 1.26.3 and `libnginx-mod-stream` | `nginx.service`, enabled in every mode |
| `coraza/` | `keel-overlay-coraza` | Keel's `libnginx-mod-http-coraza` 0.21.0 and `coreruleset` 4.25.1 (step 5), and `keel-overlay-nginx` | none: an Nginx module; `/usr/lib/keel/overlays/coraza/state` turns it on and off |
| `anubis/` | `keel-overlay-anubis` | Keel's `anubis` 1.27.0 (step 5), and `keel-overlay-nginx` | `anubis@keel.service` |

Every package depends on `keel (>= 0.12.0)`, the first keel that reads
`manifest_version: 1`, so apt refuses a keel that could not read the
manifest (docs/manifest-v1.md, "Versioning").

## etcd's own first start

`etcd-server`'s `postinst` starts etcd, which writes a member of a
cluster of one to `/var/lib/etcd/default`. A node must not keep it: keel
joins the node to the mesh's cluster (handbook decision 0048), and a
member directory there would bring the lone cluster back. So the
overlay's `preinst` notes whether `/var/lib/etcd/default/member` existed
before its first installation, and its `postinst`, once it has stopped
etcd, marks it (`/var/lib/keel-overlay-etcd/package-member`) only when it
did not: what `etcd-server` made in the same transaction, never data
that was there before. keel removes a marked member before it starts
etcd for the mesh's cluster, and refuses to start etcd over an unmarked
one it never started, for the operator to look at. When apt configures
`etcd-server` before it unpacks the overlay, the directory exists at
`preinst` and is not marked, so keel refuses rather than guesses.

Monit's `etcd-health` check asks `/health` on etcd's plain metrics
listener, `http://[::1]:2381`, which keel renders
(`ETCD_LISTEN_METRICS_URLS`): the client port, 2379, wants TLS and a
client certificate signed in the mesh.

## Building

```
packages/build [NAME...]
```

builds each package from a copy of its directory with
`dpkg-buildpackage -us -uc -b`, lints it with lintian (any error or warning
fails), and leaves the files in `dist/`. Nothing is signed. Publishing to
the testing track (0039) is the maintainer's attended release on the build
host (Keel-Linux/apt, docs/build-host.md); the CI job `packages` only proves
that each package builds, lints clean and does what this file says on a
trixie machine.

`keel manifest validate` does not run inside the package build: on a
machine it checks that the unit files and first boot hooks a manifest names
exist (rules 5 and 12), and those belong to the packages the overlay depends
on, which a build tree does not hold. It runs where they are installed:
`tests/overlay-install.bats`, in the CI job and on a booted container.

## The units of a simple installation

In a simple installation of Keel Core, etcd and both CrowdSec units are
installed, **disabled and stopped** (decision 0041, the Core table). The
Debian packages do the opposite: the `postinst` of `etcd-server`, `crowdsec`
and `crowdsec-firewall-bouncer` enables their units and, where systemd runs,
starts them. Later, `keel spec apply` (step 3 of 0041's plan) must be able
to enable them.

Two parts keep them in that state, and each covers a case the other cannot.

1. **The overlay's `postinst` disables and stops them on its first
   installation only** (`configure` with no previous version). dpkg
   configures `Depends` first, so it runs after the Debian packages' own
   `postinst` has enabled and started them. It uses
   `deb-systemd-helper disable`, which removes the links and keeps the
   state file, and `deb-systemd-invoke stop` only where systemd runs.
   - *What counts as a first installation.* dpkg passes no previous version
     only when nothing of the package is left. The overlay has no conffile,
     so it ships a `postrm`: with one, a `remove` leaves the package in the
     config-files state, and a later reinstall is configured as an upgrade
     from the removed version and leaves the units alone. Only after a
     `purge` is the next installation a first one again.
   - *A machine that already ran them (the transition).* `preinst`, on the
     first installation on a live system (where `/run/systemd/system`
     exists), records every unit that is already enabled, or running, in
     `/var/lib/keel-overlay-<name>/kept-units`, and `postinst` leaves those
     as they are and says so. An image build keeps nothing: in its chroot a
     unit enabled by an earlier apt run of the same build is the Debian
     package's doing, so it ends disabled whatever the order of the apt
     runs. `postinst` deletes the file once it has read it (a failed
     configuration keeps it for the retry), and `postrm` deletes it on
     purge and on abort-install. When the Debian package comes
     in the same transaction as the overlay, apt unpacks everything before
     it configures anything, so at `preinst` time the unit is unpacked but
     not yet enabled or started, and `postinst` puts it in the simple
     state. Measured both ways on a trixie container: `apt install` of the
     overlay with its Debian packages ends disabled and stopped, and an
     overlay installed where CrowdSec was enabled and running leaves it
     running. A unit nobody had turned on (the bouncer, when only
     `crowdsec` ran) is still put in the simple state.
   - *Upgrades of the Debian packages keep the state.* Their
     `dh_installsystemd` snippet re-enables a unit only while every link its
     state file records is present (`deb-systemd-helper was-enabled`), and
     `deb-systemd-invoke` never starts or restarts a disabled unit that is
     not running. This is the contract Debian keeps for an administrator
     who disabled a service, so it holds for every later upload.
   - *Upgrades of the overlay keep the state* that `keel apply` has set
     since: an upgrade is `configure` with a previous version, and the
     `postinst` does nothing then.
   - *Image builds*: fab installs under a `policy-rc.d` that exits 101, so
     `deb-systemd-invoke` starts nothing and the stop is not needed; the
     disable works in the chroot, where it only removes links.
2. **A systemd preset says `disable`** for each unit
   (`/usr/lib/systemd/system-preset/20-keel-overlay-<name>.preset`).
   Debian's presets enable every unit they do not name, and systemd applies
   them on a first boot, when `/etc/machine-id` is missing or says
   `uninitialized`, and on `systemctl preset-all`. Measured on a trixie
   container: with the presets moved aside, such a first boot enabled and
   started all three units; with them, the three stayed disabled and
   inactive. A preset alone would not do: `deb-systemd-helper`, which the
   Debian packages' maintainer scripts use, does not read presets, so a
   live `apt install` would still enable and start the units.

**Not masking.** A mask would survive every upgrade, but a masked unit is
not the `disabled` state of the manifest: `systemctl enable` refuses it and
`systemctl start` cannot start it, so `keel apply`, an operator and Webmin
would each have to know to unmask first. A disabled unit is exactly what
`systemctl enable` undoes, and `tests/overlay-install.bats` checks that
none of the units is masked.

`systemctl preset-all` run by hand disables the units again, even where the
spec enabled them; `keel diff` reports that as drift and `keel apply`
converges it.

## Upgrades where the VIP is active

The maintainer's requirement of 2026-10-10: upgrading packages never
breaks the service on a machine where the VIP is active, beyond a short
blip that keel's CI measures (keel's `docs/vip.md`, "Upgrading a pair
without downtime").

- **keel-overlay-vip** is built with `--no-stop-on-upgrade`. Its preinst
  stops nothing, and its postinst try-restarts `keel-vip.service` where it
  runs, and starts it nowhere it does not. 0.1.1's `--no-start` alone made
  the preinst stop the controller and its check on every upgrade and
  start neither again. A file trigger on keel's Python files
  (`/usr/lib/python3/dist-packages/keel`) try-restarts it on an upgrade of
  keel too, so the helper runs the new code. The restart keeps the VIP:
  keel (>= 0.21.0) carries the address with a lifetime the kernel ends at
  the release time, keeps it in ExecStopPost while the unit restarts, and
  renews the same lease from the new controller.
- **keel-overlay-etcd** ships a drop-in of `etcd.service`. Its ExecStop
  runs `keel mesh etcd gate stop`, and its ExecStartPost runs `keel mesh
  etcd gate started`. etcd-server's postinst restarts etcd on every
  upgrade. The gate makes that restart wait until every other member is
  healthy and none restarts, so two members upgraded at once never lose
  the majority. A stop is never refused for good.
- `tests/overlay-install.bats` checks four cases on a booted trixie
  container, upgrading to a built package with a bumped version: a
  running controller restarted, a stopped one left stopped, an upgrade of
  keel restarting it through the trigger, and etcd restarting through its
  gate.

## CrowdSec's identity: work for step 4 (tracker#47)

trixie's `crowdsec` registers the machine with its local API (keyed on
`/etc/machine-id`) and with CrowdSec's central API in its `postinst`, and
`crowdsec-firewall-bouncer` adds itself as a bouncer and stores the key. In
an image build that happens once, so every machine made from the image would
share one identity. This package does not change it; the Core image and
keel's enable path must:

- at image build, delete `/etc/crowdsec/local_api_credentials.yaml`,
  `/etc/crowdsec/online_api_credentials.yaml`,
  `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local` and its
  `.id`, and `/var/lib/crowdsec/data/crowdsec.db`;
- on keel's first enable of the overlay, run
  `cscli machines add --auto --force`, `cscli capi register` and
  `cscli bouncers add`, then write the bouncer key into the `.local` file;
- remember that `cscli capi register` fails without network, as the
  package's own `postinst` already does at installation.

## The Web overlays

Keel Web is Core plus `nginx`, `coraza` and `anubis` (decisions 0030,
0036 and 0041, step 6). In a simple installation Nginx runs and Coraza and
Anubis are installed and off; in the cloud modes all three run.

**Nginx** stays as trixie ships it: `nginx.conf` and Debian's default site
are not touched (0042 removes the default site's link only when keel
renders a `default_server` of its own). The overlay adds, at Debian's
include points:

- `conf.d/keel-health.conf`: `/keel-health` answering 204, the probe of
  the manifest's `nginx` check, in a server that listens on `[::1]:80` and
  `127.0.0.1:80` only. Nginx hands a request to the servers listening on
  the exact address it arrived on before the wildcard ones, so this server
  answers everything sent to the loopback on port 80, whatever its Host;
  a site is reached on its own addresses, and Keel Web's internal hops use
  unix sockets. The 204 comes from `try_files`, not `return`: `return`
  answers in the rewrite phase, before Coraza sees the request, and
  Coraza's probe goes to this same location (measured: with `return`, the
  probe got 204 with the WAF on).
- `modules-enabled/90-keel-streams.conf`, `streams-available/`,
  `streams-enabled/` and `/run/nginx` (tmpfiles), the layout 0042 renders
  sites into.

**Coraza** is a module, so it has no unit, and "disabled" means the module
is not loaded at all: no link in `modules-enabled/` (the engine is loaded
in every worker; with the Core Rule Set a worker grows from about 4 to
about 65 MiB). `dh_nginx` links it on the module package's fresh
installation, so the overlay's `postinst` removes that link on the
overlay's first installation, with the same `preinst` record of a link
that was there before on a live system as CrowdSec's units have above.
The module package's upgrades link again only after its own remove, so
they keep the state.

`/usr/lib/keel/overlays/coraza/state enabled|disabled` is the hook that
turns it on and off. **keel 0.14.0 does not run it** (see below). Enabled
links the module and `/etc/nginx/coraza/keel.conf` (as
`conf.d/keel-coraza.conf`), runs `nginx -t`, reloads, and then checks what
`nginx -t` cannot: a rule Coraza refuses passes `nginx -t`, and at the
reload every worker dies and every request hangs (upstream
corazawaf/coraza-nginx#139, reproduced on trixie with
`SecRule ARGS "@rx (" ...`). So it waits for the manifest's probe to get
403 and `/keel-health` 204; if they do not within ten seconds it puts the
links back as they were, reloads again, checks that Nginx answers, and
fails naming the cause (no worker left, or the status the probe got). A
reload that fails rolls back the same way. `nginx -s reload` only signals
the master, so before probing the hook waits until no worker of before
the reload still takes requests: otherwise an old worker that already
had the rule set answers 403 while the new ones die (measured, in the
upgrade below). It refuses to turn Coraza on while Nginx is not running,
since there would be nothing to check. Disabled removes both links,
reloads and checks that the probe passes and `/keel-health` answers.
Runs are serialised with `flock` on `/run/lock/keel-overlay-coraza.lock`.

`keel.conf` turns `coraza_delay_response_headers` off. Held for phase 4
(the module's default), the response headers reach gzip only after a
sendfile buffer has gone by, and a static file asked for with gzip comes
back as an empty gzip stream (Keel-Linux/libnginx-mod-http-coraza#2):
blank pages in every browser. Measured on the Keel Web image with
0.21.0-0keel1: with the delay off the page is whole and the Core Rule Set
still answers 403 in phase 2, and a phase 4 deny resets the connection
instead of answering a clean 403. `sendfile off`, the other way, cannot be
said from `conf.d/`: Debian's `nginx.conf` sets `sendfile` in the same
http context and `nginx -t` refuses the duplicate. The line goes once
0.21.0-0keel2, which holds the body in memory whenever the headers are
held, is installed.

**The audit log** says which rule blocked. Nginx's error log only says
`Coraza: Access denied with code 403, unique_id "..."`.
`keel-rules.conf` has Coraza write `/var/log/coraza/audit.log`: one JSON
object a line (`SecAuditLogFormat JSON`), for each request it blocked
and each answer 4xx or 5xx other than 404 (`RelevantOnly`). The
`transaction.id` of the line is the error log's `unique_id`, and
`messages[].error_message` holds each rule that matched in ModSecurity's
format (`[id "941100"] [msg "XSS Attack Detected via libinjection"]
[data "..."] [severity "critical"]`), so CrowdSec can parse the file
later. Parts A, H and Z only: the client and the matches, each naming the
host and the URI, never a header or a body. Part B, the request headers,
is left out because it carries `Cookie` and `Authorization` and Coraza
has no action to redact them. The workers write the file as `www-data`,
so it cannot be root's: the file is 0600 and the directory
`www-data:www-data 0700`, made at boot by the package's tmpfiles.d entry
(a worker that cannot open the file dies with its WAF). It is rotated
daily or at 100 MiB, whichever comes first, by
`keel-overlay-coraza-logrotate.timer`, which runs logrotate every hour on
`/etc/keel-overlay-coraza/logrotate.conf` alone (not in
`/etc/logrotate.d`, whose run is daily), copying and truncating, since
Coraza keeps the file open. A request served normally writes nothing,
even when a rule only warned (measured: a request by IP matches CRS
920350 and is not logged).

**Keel's exclusions** are `/etc/nginx/coraza/keel-exclusions.conf`,
read before the Core Rule Set; the operator's stay in coreruleset's files.
There are two, both for Anubis's challenge. Its page sends the browser to
`/.within.website/x/cmd/anubis/api/pass-challenge` with `redir`, the URL
first asked for. Opened by IP, that URL names an IP, and the Core Rule
Set scored 5, the blocking threshold, so no browser passed the challenge
by IP: by IPv4 CRS 931100 ("URL Parameter using IP Address", tag
`attack-rfi`), by IPv6 CRS 932130 ("Unix Shell Expression Found", which
reads the brackets of `https://[2001:db8::1]/` as a shell glob). CRS
920350, "Host header is a numeric IP", only warns, with 3. Rule 10001
removes `ARGS:redir` from 931100 and 932130 only, on that one path only,
and for GET only: Anubis serves pass-challenge for GET, and a POST or PUT
to the same path falls through to its `/` handler, which proxies it to
the application. The path is compared whole (`@streq`) after
`t:normalisePath` alone, as Nginx and Anubis route it: Coraza's
`REQUEST_FILENAME` is already decoded once, so a second decode would let
`pass-%2563hallenge` match and reach the application, and it keeps dot
segments, so a prefix match let `/.within.website/../x.php` and
`%2e%2e` reach another location with the rules lifted. Every other rule
still reads `redir`, and every other argument and path keeps them all
(tests/overlay-web.bats). Anubis does not check `redir`'s host itself
unless `REDIRECT_DOMAINS` is set; keel-web sets it.

Rule 10002 is for a site opened by a `*.localhost` name, which only the
machine itself resolves (RFC 6761). Its `redir` names localhost, and CRS
934190 ("Scheme-less localhost or internal hostname", `attack-ssrf`)
scored 5 and blocked pass-challenge. On the same path, for GET only and
compared the same way, 934190 no longer reads `redir` when there is exactly one (query and
body together, hence phase 2), the request's `Host` is `localhost` or a
name under it (with or without a port), and `redir` starts with
`https://` followed by that very `Host` and `/`. Another localhost name, a
longer name, user information, another port, plain http, a request by
another name or by address, a second `redir`, another path or another
argument is still blocked, and every other rule still reads `redir`
(tests/overlay-web.bats). No server-side request follows `redir`: Anubis
redirects the browser, to the request's own host only (anubis#3).

`state recheck` guards upgrades. The overlay's dpkg trigger watches
`/usr/share/coreruleset`, the module and `libcoraza.so.1`; when any of
them is upgraded under an enabled Coraza with Nginx running, `postinst
triggered` reloads, checks the probe the same way, and turns Coraza off
when the new files fail (measured with a coreruleset carrying a rule
Coraza refuses: the upgrade completes, Coraza is off, Nginx answers). The
upgrade itself does not fail; Monit's `waf-blocks` check reports Coraza
off until it is turned on again.

**Only these runs are guarded**: `state enabled`, `state recheck` and
`state disabled`. Any other reload still reaches corazawaf/coraza-nginx#139
unchecked: one by hand, the reload after a certificate renewal, the
`nginx-reload` trigger of another `libnginx-mod-*` package, and an edit of
the rule set's conffiles under `/etc/coreruleset` followed by a reload.
Monit's `nginx` check (a restart, which does not help) and `waf-blocks`
check (an alert) are what report those.

A remove of the overlay takes Coraza out of Nginx: `prerm remove` deletes
both links and the `nginx-reload` trigger reloads a running Nginx, so
apt autoremoving the module or the rule set afterwards cannot break the
next reload. A reinstall finds Coraza off.

**Anubis** runs as `anubis@keel.service`, an instance of the anubis
package's template unit, reading `/etc/anubis/keel.env`: `[::1]:8923`
only, metrics on a unix socket in its runtime directory, upstream's
default policy as the one policy of version 1 (0042), and what it allows
handed back to Nginx on `unix:/run/nginx/keel-app.sock`. A location goes
through it with `include /etc/nginx/snippets/keel-anubis.conf`. The
anubis package enables nothing, so the overlay has no state to undo and
nothing to keep; the instance is disabled and stopped after installation.
`[::1]` and not a unix socket: anubis supports both, but the manifest's
check is a TCP probe of port 8923, and version 1 of the format has no
socket check.

Its signing key (the manifest's `anubis_signing_key`, `generate:
required`, `shared: true`) is `/etc/anubis/keel.key`. The package's unit
refuses to start without it; a drop-in makes `anubis@keel.service`
require `keel-overlay-anubis-key.service`, which runs
`/usr/lib/keel-overlay-anubis/signing-key` when the key is not there.
Nothing runs it at installation or in an image build, so no image carries
a key. At the first start, the one `keel spec apply` makes when the spec
enables the overlay, it follows the instance spec (the manifest owns the
policy, the spec the file, 0041):

- `secrets.anubis_signing_key: {file: PATH}`: the key becomes a link to
  PATH; a PATH that is not there is refused, and the start fails;
- `database.server.role: replica`, or `/etc/anubis/keel.key.from-primary`
  present: the key is shared and the primary's, so none is made and the
  start fails until it is put in place (the spec has no role for a web
  node, hence the marker for keel to write);
- otherwise it generates one.

A key that is there is never replaced. A purge stops and disables
`anubis@keel.service`, whose environment file it deletes, and deletes the
key (a link, when the spec named the file).

The manifests depart from the worked example of docs/manifest-v1.md in
two places, both for Anubis: the unit is `anubis@keel.service`, not
`anubis.service`, because step 5 packaged a template; and its port
declares `address: "::1"`, the one family it binds. The erratum to the
format is Keel-Linux/handbook#33.

### What keel 0.14.0 does with them, and what it lacks

Measured on the Core image of step 4 with keel 0.14.0, a spec naming the
`web` appliance (its manifest placed by hand until step 7 ships
`keel-web`) and `coraza: enabled`, `anubis: enabled`:

- Anubis converges: `apply --system` enables and starts
  `anubis@keel.service`, the key is generated on that start, and Monit's
  `anubis` check passes.
- Monit's file gains `waf-blocks`, but nothing loads Coraza: keel
  converges units, and the overlay has none. The check fails (the probe
  gets 204) until the hook runs; after `state enabled` it passes.

What keel needs, for step 7 or the implementation of 0042
(Keel-Linux/keel#62):

1. Run `/usr/lib/keel/overlays/<name>/state enabled|disabled` when an
   overlay's state changes and the file exists, after its `requires`
   came up and before its dependants, and fail the step when it fails.
   The rollback of corazawaf/coraza-nginx#139 is in the hook; keel only
   has to call it and report.
2. `inspect` and `diff` for an overlay without units: the hook could
   answer `state status`; today `diff` says "not compared".
3. Secrets: `generate: true` in the spec makes a short random token for
   the first boot conf (`KEEL_SECRET_<NAME>`), which is not an Anubis key
   and reaches no file Anubis reads. The installer's emitter should write
   `anubis_signing_key: {file: /etc/anubis/keel.key}` for a generated
   key, and a node that receives its primary's shared secrets (0028)
   should get the primary's key, writing the `from-primary` marker until
   it has.
4. Monit encodes the `%` of the waf-blocks path again
   (`%253Cscript...`); the Core Rule Set still blocks it (403, measured),
   but the renderer may want to pass the path undecoded on purpose.

## Tests

`tests/overlay-web.bats` runs on a disposable trixie machine booted with
systemd, with the three Web overlays and their dependencies installed
(`KEEL_OVERLAY_INSTALL_TEST=1`, `OVERLAY_DEBS` the directory holding the
overlay packages, `libnginx-mod-http-coraza` and `coreruleset`). The CI
job `web` runs it in a booted trixie LXC system container on keel-lxc-1,
with step 5's packages built there; it also ran on an LXC container of
the Core image on the test machine. It checks the
manifests on the machine, `/keel-health` on both loopbacks and not on the
machine's own addresses, Debian's `nginx.conf` and default site
untouched, Coraza off after a first installation (with the module
installed in the same transaction, before, and in an image build) and
after an upgrade of the module, the hook on and off and its rollback of a
rule Coraza refuses, a blocked request in the audit log as JSON naming
its rules and a served one not in it, Anubis's `redir` carrying an IP
let through on Anubis's paths only, a remove taking Coraza out of Nginx, a rule set
upgrade rechecked and kept, and one that kills the workers turning Coraza
off; Anubis off, its key made at the first start and kept across a
restart, the spec's key file linked, no key and no start where the
from-primary marker is, listening on `[::1]` only, Nginx proxying
through it, and a purge stopping and disabling it and deleting the key. `tests/coraza-state.bats` and
`tests/anubis-signing-key.bats` unit test the two scripts with stubs, and
`tests/coverage.sh` measures them.

`tests/overlay-install.bats` runs on a disposable trixie machine with the
four Core packages installed (it refuses to run unless
`KEEL_OVERLAY_INSTALL_TEST=1`). It checks that:

- each manifest validates with `keel manifest validate`;
- the three units are disabled, and inactive where systemd runs;
- the preset reads `disable`, and a first boot preset leaves the units
  disabled;
- after a purge, a first installation disables what the Debian packages
  enabled in the same transaction;
- a first installation on a live system leaves a unit that was enabled and
  running before it, and one in an image build (no `/run/systemd/system`,
  hidden under a tmpfs where systemd runs) disables it;
- `kept-units` is deleted by a purge after an unconfigured unpack, and by
  an unpack that fails after `preinst` (abort-install), and survives a
  failed configuration so the retry keeps what was recorded;
- remove and reinstall keep an enabled etcd enabled and active;
- real version upgrades keep the state: the Debian packages and the overlay
  are rebuilt with `dpkg-deb` under a higher version and installed over the
  current ones, whether the units are disabled or enabled by `keel apply`.
