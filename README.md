# TripleBoot

Production-grade UEFI/GPT triple-boot helper for a workstation running:

- Ubuntu Linux
- Windows 10/11
- macOS experiments through OpenCore on compatible x86 hardware

This repository is intentionally conservative. It automates the safe parts: scanning, planning, EFI backup, guarded partitioning, Ubuntu swapfile setup, boot reporting, OpenCore scaffold generation, and validation hooks. It does **not** pretend that Hackintosh/OpenCore can be solved by a magic generic `config.plist`.

## Core warning

Your discussed target machine includes an **NVIDIA RTX 2070**. That GPU is not a viable macOS hardware-acceleration path. For bare-metal macOS, use a compatible Intel iGPU path or a supported AMD GPU. Otherwise treat macOS as a lab/VM-grade experiment.

## Recommended layout

### Disk A — Ubuntu

| Partition | Size | Format | Label |
|---|---:|---|---|
| EFI | 1 GiB | FAT32 | `UBUNTU_EFI` |
| Root | Rest | ext4 | `UBUNTU_ROOT` |

Ubuntu swap is a **swapfile**, not a shared swap partition.

### Disk B — Windows + macOS placeholder

| Partition | Size | Format | Label |
|---|---:|---|---|
| EFI | 1 GiB | FAT32 | `WINMAC_EFI` |
| MSR | 16 MiB | Microsoft Reserved | `MSR` |
| Windows | 500 GiB | NTFS | `WINDOWS` |
| macOS | Rest | APFS placeholder | `MACOS_APFS` |

The macOS partition is intentionally left unformatted by the script and should be formatted from the macOS installer/Disk Utility.

## Fast start

```bash
chmod +x scripts/tripleboot_aio.sh
sudo scripts/tripleboot_aio.sh install-deps
sudo scripts/tripleboot_aio.sh scan
sudo scripts/tripleboot_aio.sh analyze
sudo scripts/tripleboot_aio.sh boot-report
```

Partition only after validating disk names:

```bash
sudo scripts/tripleboot_aio.sh partition \
  --ubuntu-disk /dev/nvme0n1 \
  --winmac-disk /dev/nvme1n1 \
  --yes-destroy
```

Build an OpenCore scaffold after downloading OpenCore/kexts:

```bash
sudo scripts/tripleboot_aio.sh download-opencore
sudo scripts/tripleboot_aio.sh download-kexts
sudo scripts/tripleboot_aio.sh build-opencore-scaffold \
  --gpu-policy disable-nvidia \
  --smbios iMac20,1
sudo scripts/tripleboot_aio.sh validate-opencore
```

## Repository map

```text
.
├── scripts/tripleboot_aio.sh
├── docs/
│   ├── 00-safety.md
│   ├── 01-disk-layout.md
│   ├── 02-install-order.md
│   ├── 03-opencore.md
│   ├── 04-gpu-notes.md
│   ├── 05-troubleshooting.md
│   └── 06-recovery.md
├── examples/tripleboot.env.example
├── STATE.md
└── .github/workflows/shellcheck.yml
```

## Non-negotiables

- Boot installers in UEFI mode only.
- Back up EFI partitions before editing anything.
- Suspend BitLocker before changing ESP or boot entries.
- Never use a shared swap partition across OSes.
- Validate generated OpenCore configs with `ocvalidate` from the same OpenCore release.
- Treat all destructive actions as live-fire operations.
