# Evidence: an lz4 initrd, 2026-10-27

Change: `common/conf/keel-boot/initramfs-compress` sets `COMPRESS=lz4`
and runs `update-initramfs -u -k all`. Decision 0071. Test:
`tests/plans-boot.bats` (9 tests, all pass), which checks the boot
layer's conf and overlay but not the boot time.

Platform: the boot layer is the ISO's layer on top of the appliance
layer; it is not the Core layer that `04-boot-layer.sh` boots. This run
(02/05) measures the Core layer, whose initrd is still zstd and whose
GRUB is not used by the direct-kernel test disk. The boot layer's own
boot time is the measurement this evidence waits for.

## Commands

```text
$ sed -i 's/^COMPRESS=.*/COMPRESS=lz4/' /etc/initramfs-tools/initramfs.conf
$ update-initramfs -u -k all
```

## What it shows

The file is applied by `buildtasks/products/boot`'s
`COMMON_CONF = keel-boot`; `plans-boot.bats` confirms the boot layer has
the kernel, the initrd, GRUB, the live boot and the installer. The lz4
decompression needs a boot of the built boot layer; that is the next
measurement, not this one.

## Rejected

`MODULES=dep` (the image boots hardware the build host did not have) and
`mitigations=off` (a security tradeoff, not a performance default).

## Measured on the Core layer, 2026-10-27

The test disk used the released layer's 6.12.111 kernel, initrd and
modules because the new Core layer carries no `/boot`; the rootfs is the
new build. `systemd-analyze` on its first boot:

```text
Startup finished in 2.028s (kernel) + 3.307s (userspace) = 5.336s
1.152s keel-host-keys.service
 898ms networking.service
 828ms systemd-binfmt.service
 658ms dev-vda.device
 405ms postfix.service
```

`systemd-binfmt` is in the critical chain for 828 ms and the appliance
uses no handler, so `keel-core/conf.d/main` masks it and its automount.
`keel-host-keys` generates independent keys; its 22 tests pass with the
three SSH keys, TLS and snakeoil in parallel. The boot-layer GRUB/lz4
change is still separate and not in this Core measurement.

## After the binfmt mask

The next Core boot, with the `keel-core` mask and the same released
6.12.111 boot set, measured:

```text
Startup finished in 1.988s (kernel) + 2.877s (userspace) = 4.866s
1.581s networking.service
1.327s keel-host-keys.service
 834ms dev-vda.device
 364ms postfix.service
```

`systemd-binfmt.service` is gone from `systemd-analyze blame`, and there
are no failed units. `networking` is now the largest unit; the 1.327 s
`keel-host-keys` is the image's apt inithooks, not the parallel
2.3.6+keel27 build, which is the next measurement.

## RNG re-measure, 2026-10-28

The 04 test disk now has `-smp 4`, `-device virtio-rng-pci` and a 2G
disk. The Core boot measured:

```text
Startup finished in 2.119s (kernel) + 2.585s (userspace) = 4.705s
1.066s keel-host-keys.service
 930ms networking.service
 494ms dev-vda.device
 377ms postfix.service
```

There are no failed units and `systemd-binfmt` is still absent. The
earlier 5.881 s run used 2 vCPUs and no RNG, so its 1.719 s
`keel-host-keys` was entropy-bound; the parallel build measures 1.066 s
here against the apt build's 1.327 s. The 2G disk also cut `dev-vda`
from 873 to 494 ms. The boot-layer GRUB/lz4 change remains separate.

## Masks and the boot layer, 2026-10-28

With the six masks, the first-boot mode and the built boot layer
(kernel 6.12.113, 43M lz4 initrd):

```text
Startup finished in 2.143s (kernel) + 2.294s (userspace) = 4.437s
1.126s networking.service
 939ms keel-host-keys.service
 435ms dev-vda.device
 374ms postfix.service
 256ms turnkey-init-fence.service
 149ms lvm2-monitor.service
```

`dev-hugepages`, `dev-mqueue`, `sys-kernel-debug`, `sys-kernel-tracing`,
`run-lock` and `tmp` are gone from blame; 0 failed units. The boot is
4.437 s, down from 4.705 s, and userspace is 2.294 s. `turnkey-init-fence`
is the first-boot path, enabled by the 04 FIRSTBOOT mode; the inithooks
service ran and reached graphical.target.

## Final Core, 2026-10-28

The Core image with the six masks, the Webmin/Python trims and the
6.12.113 boot layer:

```text
Startup finished in 2.095s (kernel) + 2.393s (userspace) = 4.488s
 935ms keel-host-keys.service
 783ms networking.service
 477ms dev-vda.device
 365ms postfix.service
 226ms turnkey-init-fence.service
 139ms lvm2-monitor.service
  88ms blk-availability.service
```

The first-boot inithooks ran `00declarative`, `01ipconfig`,
`05autogrow-fs`, `09hostname`, `10keel-system`, `10randomize-cronapt`,
`10randomize-crontab` and `15regen-sslcert` in about 1 s; `keel-host-keys`
generated the SSH/TLS/snakeoil keys in parallel.

## Final stable first boot, 2026-10-28

With the TLS restored to `keel-host-keys`, the fence ordered after
`inithooks.service`, and the RSA key type:

```text
6.105s (2.209 kernel + 3.895 userspace)   [networking 2.417s = test DHCP]
1.231s keel-host-keys.service
 475ms postfix.service
 288ms turnkey-init-fence.service
0 failed units
```

The fence passes; `turnkey-init-fence` is no longer failed. The TLS
deduplication and the ECDSA experiment are reverted: the fence needs the
TLS at `keel-host-keys` time, and its mini server did not start with the
deduplicated ECDSA path.
