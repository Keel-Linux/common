# Evidence: Python bytecode precompiled at build, 2026-10-21

Change: `mk/turnkey.mk`, `_root.patched/post` now runs `compileall` with
timestamp invalidation after the product deb and before `seal-root`, over
the standard library, `dist-packages`, `confconsole` and `sitecustomize`.
Tests: `tests/mk-identity.bats` (16 tests, all pass).

Platform: the released Core layer, sha256 below, run in two ways on one
developer workstation: an unprivileged container (no systemd), and
qemu/KVM as a normal user with the layer's own kernel and initrd. This is
not a Proxmox CT, a mesh node or the build host, so per decision 0053 it
is supporting evidence, not the real-platform test. The real test is a
build on the build host and a boot of that artifact.

## Where and when

- Host: eclipse (developer workstation), 2026-10-21, 13:00-13:40 UTC.
- Container: `docker run --rm keel-core:19.0-9`, no privileges.
- VM: `qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2`, root on a
  virtio disk made from the layer with `fakeroot` + `mke2fs -d`.

## Versions

```text
ii  keel                   0.20.0       all   Declarative management of one appliance instance
ii  keel-archive-keyring   0.2.0        all   GnuPG archive key of the Keel Linux package repository
ii  keel-core              0.1.3        all   Keel Core, the appliance every Keel appliance is built on
ii  keel-overlay-crowdsec  0.1.0        all   Keel overlay: CrowdSec and its firewall bouncer
ii  keel-overlay-etcd      0.2.0        all   Keel overlay: etcd, the mesh registry
ii  keel-overlay-installer 0.1.0        all   Keel overlay: the installer
ii  keel-overlay-vip       0.1.1        all   Keel overlay: the service VIP of a replicated pair
ii  keel-overlay-wireguard 0.1.0        all   Keel overlay: WireGuard, the mesh

$ keel --version
0.19.0

$ python3 --version
Python 3.13.5
```

The `keel` package is 0.20.0 and `keel --version` prints 0.19.0: the known
mismatch of keel#98, unrelated to this change.

## Artifacts

```text
6f0a5590385d6294da52040eb2365851f43d8f59ed7a6b4b0a2b7affb72fca56  core.tar.zst
```

## Commands and output

### Before: the image ships no bytecode

```text
$ dirs="/usr/lib/python3.[0-9]* /usr/lib/python3/dist-packages /usr/lib/confconsole /etc/python3.13"
$ for d in $dirs; do \
    printf "%s py=%s pyc=%s\n" "$d" \
      "$(find $d -name '*.py' | wc -l)" "$(find $d -name '*.pyc' | wc -l)"; done
/usr/lib/python3.13 py=598 pyc=0
/usr/lib/python3/dist-packages py=454 pyc=0
/usr/lib/confconsole py=36 pyc=0
/etc/python3.13 py=1 pyc=0
```

### The new build step

```text
$ export SOURCE_DATE_EPOCH=1700000000
$ dirs="/usr/lib/python3.[0-9]* /usr/lib/python3/dist-packages /usr/lib/confconsole /etc/python3.13"
$ find $dirs -name "*.py" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
$ python3 -m compileall -q -f -j0 --invalidation-mode=timestamp $dirs
$ find $dirs -name "*.pyc" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

$ find $dirs -name "*.pyc" | wc -l
1089
$ stat -c "%Y" "$(find $dirs -name '*.pyc' | head -1)"
1700000000
$ python3 - "$(find $dirs -name '*.pyc' | head -1)" <<'PY'
import sys, struct
d = open(sys.argv[1], "rb").read(16)
print("flags", struct.unpack("<I", d[4:8])[0], "src mtime", struct.unpack("<I", d[8:12])[0])
PY
flags 0 src mtime 1700000000
```

Size, from `find -type f -printf '%s\n'` summed over the two directories:

```text
before: 21443496 bytes
after:  40283897 bytes
delta:  +18840401 bytes (+18.0 MiB)
```

Time to compile (`date +%s%N` around the command):

```text
compileall: 840-1186 ms (two runs, -j0)
```

### First call after the build

```text
$ keel --help      # 1st
191 ms
$ keel --help      # 2nd
197 ms
```

The released layer without bytecode was 632 ms on the first call and
184 ms warm (recorded in /data/keel-perf/FINDINGS.md). The ~450 ms
penalty is gone.

Confconsole's own modules (`conf`, `ifutil`, `ipaddr`, `keelbanner`), which
the first-boot console imports:

```text
$ python3 -c "import sys;sys.path.insert(0,'/usr/lib/confconsole');import conf,ifutil,ipaddr,keelbanner"
cold, no .pyc    320 ms
warm             61 ms
precompiled      68 ms
```

### Reproducibility, two separate containers

```text
$ find $dirs -name "*.pyc" -exec sha256sum {} + | sort -k2 | \
    sed "s|/usr/lib/[^ ]*/||" | sha256sum
4888458c48960104e8b8303d0793924195ccc784923561d1cf25230e0a322675  -
4888458c48960104e8b8303d0793924195ccc784923561d1cf25230e0a322675  -
```

### Invalidation still works

```text
$ pyc=/usr/lib/python3/dist-packages/keel/__pycache__/cli.cpython-313.pyc
$ src=/usr/lib/python3/dist-packages/keel/cli.py
$ echo "before: pyc_mtime=$(stat -c %Y $pyc) src_mtime=$(stat -c %Y $src)"
before: pyc_mtime=1700000000 src_mtime=1700000000
$ sleep 1; touch $src
$ echo "after touch: pyc_mtime=$(stat -c %Y $pyc) src_mtime=$(stat -c %Y $src)"
after touch: pyc_mtime=1700000000 src_mtime=1792535337
$ python3 -c "import keel.cli"
$ echo "after import: pyc_mtime=$(stat -c %Y $pyc)"
after import: pyc_mtime=1792535337
$ # header now records the new source mtime
header src mtime 1792535337
```

### Boot, and the postfix correction

A disk built with `unshare -r mke2fs -d` lost the spool ownership:

```text
$ debugfs -R "ls -l /var/spool/postfix" disk.img        # unshare -r
40700 ... 0 0 ... active
$ debugfs -R "ls -l /var/spool/postfix" disk-fakeroot.img
40700 ... 103 0 ... active
$ debugfs -R "ls -l /var/spool/postfix" disk-fakeroot.img
40730 ... 103 105 ... maildrop
```

The released layer has the same `103`/`105` ids. On the fakeroot disk:

```text
[  OK  ] Started postfix.service - Postfix Mail Transport Agent
...
Startup finished in 2.076s (kernel) + 3.925s (userspace) = 6.002s   # first boot
----BLAME----
 766ms postfix.service
...
Startup finished in 2.113s (kernel) + 3.147s (userspace) = 5.261s   # steady
----BLAME----
1.036s postfix.service
 860ms systemd-binfmt.service
 719ms dev-vda.device
 582ms turnkey-init-fence.service
 492ms networking.service
 222ms dev-hugepages.mount
```

Steady boot repeated: 3.131 s userspace, postfix 1.002 s, no failed units.
The earlier 2.66 s steady boot had postfix aborting, so it was faster for
the wrong reason.

## What it shows

The new step writes 1089 `.pyc` files, keeps timestamp invalidation
(flags 0, source mtime = `SOURCE_DATE_EPOCH`), reproduces byte-for-byte
across two containers, and removes the ~450 ms first-call compile cost
(632 ms to ~191 ms; confconsole's imports 320 ms to 68 ms). It costs
~18.0 MiB and 0.8-1.2 s of build time. It does
not show a build on the build host or a boot of that built artifact, and
it does not show the boot-time effect of bytecode (the first-boot hooks
were not timed here). The postfix failure recorded earlier was the test
disk's ownership, not the image.

## TKLDev build, 2026-10-27

A real build on the TKLDev 19.0 VM (Debian trixie, Python 3.13), not the
container:

```text
build1 pyc count: 1120
build2 pyc count: 1120
pyc aggregate build1: 9a65633162221966af45435a8552e052970f4e357203053f2c036101a0c5942e
pyc aggregate build2: 9a65633162221966af45435a8552e052970f4e357203053f2c036101a0c5942e
BYTECODE: identical across the two builds
STALE: none
CONTROL: no bytecode without SOURCE_DATE_EPOCH
```

The first run's stale check reported `sitecustomize.pyc`: the checker
followed the absolute `/etc/python3.13/sitecustomize.py` symlink to the
**host's** file. The fixed check resolves an absolute symlink inside the
extracted rootfs and passes with no stale file. The control needed
`TERM=dumb` for `fab-chroot`, and the control target is `root.patched`,
not the default ISO target.

The built Core layer carries no `/boot` (the boot set is the boot
layer's, 0052), so the boot test used the released layer's 6.12.111
kernel, initrd and modules with the new rootfs. The image's `keel` is
0.23.56: `keel --help` 274 ms cold / 215 ms warm, import profile
179676 us. The lazy 0.20.0 package measured 40/31 ms and 8428 us; the
0.23.56+perf1 port is the current run.

### The 0.23.56+perf1 image, 2026-10-27

The image's before was 1120 `.pyc` and `keel --help` 230/182 ms with
`import keel.cli` 153949 us. The local 0.23.56+perf1 upgrade measured
42/29 ms and 8230 us, 1122 `.pyc` after `py3compile`, flags 0, source
mtime `SOURCE_DATE_EPOCH`, and no failed units. The Build 1/2 aggregate
is identical; the control is 0.

## Fast build, 2026-10-28

The 02 build now runs one full product build, a second compile of the
same exported rootfs, and a targeted negative control. The bootstrap was
skipped because the TKLDev disk kept it, and 02 took **5m10s** instead of
about 21 minutes.

```text
build1 pyc count: 1120
second-compile pyc count: 1120
pyc aggregate build1: 9a65633162221966af45435a8552e052970f4e357203053f2c036101a0c5942e
pyc aggregate second compile: 9a65633162221966af45435a8552e052970f4e357203053f2c036101a0c5942e
BYTECODE: identical after the second compile
STALE: none
CONTROL: no bytecode without SOURCE_DATE_EPOCH
MK-IDENTITY: 16/16
```

The layer tar cannot be byte-identical across builds because of
install-time state, so the reproducibility claim is the pyc aggregate.
The control is the same SDE-gated block on the build-1 rootfs with every
`.pyc` removed; `tests/mk-identity.bats` asserts the gating. `STRICT=1`
in 02 keeps the old build1/build2/full-control run when a full-layer
comparison is wanted. The local 0.23.56+perf1 keel adds 2 `.pyc` on
install (1120 -> 1122).
