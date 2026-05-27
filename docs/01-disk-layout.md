# Disk Layout

## Recommended two-disk design

This project uses a two-disk strategy because it reduces bootloader cross-contamination and makes recovery easier.

## Disk A: Ubuntu

| Partition | Size | Type | Filesystem | Label |
|---|---:|---|---|---|
| 1 | 1 GiB | EFI System | FAT32 | `UBUNTU_EFI` |
| 2 | Rest | Linux root | ext4 | `UBUNTU_ROOT` |

Ubuntu uses a swapfile:

```bash
sudo scripts/tripleboot_aio.sh setup-swap --size 32G
```

## Disk B: Windows + macOS placeholder

| Partition | Size | Type | Filesystem | Label |
|---|---:|---|---|---|
| 1 | 1 GiB | EFI System | FAT32 | `WINMAC_EFI` |
| 2 | 16 MiB | Microsoft Reserved | MSR | `MSR` |
| 3 | 500 GiB | Microsoft Basic Data | NTFS | `WINDOWS` |
| 4 | Rest | Apple APFS placeholder | unformatted | `MACOS_APFS` |

The macOS partition is intentionally not formatted by Linux. Format it as APFS from the macOS installer or Disk Utility.

## Why include a Windows MSR partition?

On GPT disks, Windows expects a Microsoft Reserved partition. The AIO script includes a 16 MiB MSR partition before the Windows NTFS partition.

## NVMe naming

The script uses a `part_name` helper so `/dev/nvme0n1` becomes `/dev/nvme0n1p1`, not `/dev/nvme0n11`.

## Dry run

Before touching a real disk:

```bash
sudo scripts/tripleboot_aio.sh --dry-run partition \
  --ubuntu-disk /dev/nvme0n1 \
  --winmac-disk /dev/nvme1n1 \
  --yes-destroy
```
