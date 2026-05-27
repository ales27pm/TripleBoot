# Troubleshooting

## Script refuses to partition the selected disk

The script checks whether a selected disk appears to be the running root disk. This is intentional. Use a live USB for destructive partitioning.

Override exists but should be rare:

```bash
sudo scripts/tripleboot_aio.sh --force partition ...
```

## NVMe partition names look wrong

They should look like:

```text
/dev/nvme0n1p1
/dev/nvme0n1p2
```

Not:

```text
/dev/nvme0n11
```

The AIO script uses a partition-name helper to avoid this bug.

## OpenCore validation fails

Use the `ocvalidate` binary from the same OpenCore release used to create the scaffold. Do not mix new `ocvalidate` with old `Sample.plist` or old OpenCore binaries.

## Windows triggers BitLocker recovery

This can happen after EFI/UEFI changes. Boot Windows, suspend BitLocker, confirm recovery key backup, then retry bootloader work.

## GRUB does not show Windows

Boot Ubuntu and run:

```bash
sudo os-prober
sudo update-grub
```

Some distributions disable OS probing by default. You may need to set:

```text
GRUB_DISABLE_OS_PROBER=false
```

in `/etc/default/grub`, then run `sudo update-grub`.

## macOS boots to black screen

Likely GPU path issue. For RTX/Turing systems:

- Confirm `-wegnoegpu` is present if disabling NVIDIA.
- Use supported iGPU/AMD path where possible.
- Confirm display is connected to supported GPU output.
- Re-check DeviceProperties and SSDTs.

## USB devices unreliable in macOS

Build a proper USB map. Do not rely on temporary port-limit workarounds long term.
