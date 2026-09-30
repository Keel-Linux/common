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

## Tests

`tests/overlay-install.bats` runs on a disposable trixie machine with the
four packages installed (it refuses to run unless
`KEEL_OVERLAY_INSTALL_TEST=1`): each manifest validates with
`keel manifest validate`, the three units are disabled (and inactive where
systemd runs), the preset reads `disable`, a first boot preset leaves them
disabled, a first installation disables what the Debian packages enabled,
reinstalling the Debian packages keeps them disabled, and an upgrade of
either keeps a unit that `keel apply` enabled.
