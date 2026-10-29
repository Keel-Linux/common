# Evidence: a hidden GRUB menu, 2026-10-27

Change: `common/conf/keel-boot/grub-timeout` sets
`GRUB_TIMEOUT_STYLE=hidden` and `GRUB_TIMEOUT=1`. Decision 0071. Test:
`tests/plans-boot.bats` (7 tests, all pass), which checks the boot
layer's conf and overlay but not the boot time.

## What it shows

`buildtasks/products/boot` applies the file through
`COMMON_CONF = keel-boot`. `plans-boot.bats` confirms that only the boot
layer's conf touches GRUB's configuration. The menu is hidden, not
removed: Esc opens it. A held Shift at power on is not reliable on the
Proxmox noVNC console, a serial console or EFI.

## Rejected

`GRUB_TIMEOUT=0`: it removes the recovery menu where a held Shift does
not work. A visible menu: it costs three seconds on every boot.

## Measured

With `GRUB_TIMEOUT=0` the built boot layer (kernel 6.12.113) booted the
Core image at 4.4-4.5 s. The hidden menu adds the one second wait, so the
expected boot is 5.4-5.5 s. The boot time is measured on the boot layer,
not on the Core layer.
