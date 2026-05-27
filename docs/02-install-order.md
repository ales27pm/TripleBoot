# Install Order

## Recommended sequence

1. Back up existing data and EFI partitions.
2. Boot an Ubuntu live USB in UEFI mode.
3. Run `scan`, `analyze`, and `boot-report`.
4. Partition with `partition` only after confirming disk names.
5. Install Windows on the `WINDOWS` partition.
6. Install Ubuntu on the `UBUNTU_ROOT` partition and mount `UBUNTU_EFI` as `/boot/efi`.
7. Boot Ubuntu and run `setup-swap`.
8. Download OpenCore and kexts.
9. Build an OpenCore scaffold.
10. Test OpenCore from USB.
11. Only after successful USB tests, consider copying OpenCore to an internal ESP.

## Windows install notes

When selecting the Windows target, pick the NTFS partition labelled `WINDOWS`. The MSR partition already exists. If Windows wants to reformat the NTFS partition, that is fine.

## Ubuntu install notes

Use manual partitioning:

- `UBUNTU_ROOT`: mount as `/`, format ext4 if needed.
- `UBUNTU_EFI`: mount as `/boot/efi`, do not format if already prepared unless intentional.

## OpenCore install notes

OpenCore should be tested from a USB first. Do not overwrite internal EFI folders until:

- `ocvalidate` passes or only reports understood warnings.
- GPU path is confirmed.
- SMBIOS values are generated correctly.
- Required SSDTs are added.
- USB map and audio layout are reviewed.

## Optional rEFInd

rEFInd can be used as a visual selector, but it is not required. The base boot strategy can rely on firmware boot menu entries for Windows Boot Manager, Ubuntu GRUB, and OpenCore.
