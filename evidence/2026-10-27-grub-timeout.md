# Evidence: no GRUB wait, 2026-10-27

Change: `common/conf/keel-boot/grub-timeout` sets `GRUB_TIMEOUT=0`.
Decision 0071. Test: `tests/plans-boot.bats` (7 tests, all pass), which
checks the boot layer's conf and overlay but not the boot time.

## What it shows

`buildtasks/products/boot` applies the file through
`COMMON_CONF = keel-boot`. `plans-boot.bats` confirms that only the boot
layer's conf touches GRUB's configuration. The menu is a recovery tool:
hold Shift at power on to see it.

## Rejected

A non-zero timeout. It adds the wait to every boot, and the menu is not a
choice that most boots make.

## Measured

The built boot layer (kernel 6.12.113) booted the Core image at
4.4-4.5 s with the wait removed. The boot time is measured on the boot
layer, not on the Core layer.
