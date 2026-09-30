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
| `etcd/` | `keel-overlay-etcd` | trixie's `etcd-server` 3.5.16, and `keel-overlay-wireguard`, which its manifest `requires` | `etcd.service` |
| `crowdsec/` | `keel-overlay-crowdsec` | trixie's `crowdsec` 1.4.6-10 and `crowdsec-firewall-bouncer` 0.0.25 | `crowdsec.service`, `crowdsec-firewall-bouncer.service` |

Every package depends on `keel (>= 0.12.0)`, the first keel that reads
`manifest_version: 1`, so apt refuses a keel that could not read the
manifest (docs/manifest-v1.md, "Versioning").

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
     first installation, records every unit that is already enabled, or
     running, in `/var/lib/keel-overlay-<name>/kept-units`, and `postinst`
     leaves those as they are and says so. When the Debian package comes
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

## Tests

`tests/overlay-install.bats` runs on a disposable trixie machine with the
four packages installed (it refuses to run unless
`KEEL_OVERLAY_INSTALL_TEST=1`). It checks that:

- each manifest validates with `keel manifest validate`;
- the three units are disabled, and inactive where systemd runs;
- the preset reads `disable`, and a first boot preset leaves the units
  disabled;
- after a purge, a first installation disables what the Debian packages
  enabled in the same transaction;
- a first installation leaves a unit that was enabled and running before it;
- remove and reinstall keep an enabled etcd enabled and active;
- real version upgrades keep the state: the Debian packages and the overlay
  are rebuilt with `dpkg-deb` under a higher version and installed over the
  current ones, whether the units are disabled or enabled by `keel apply`.
