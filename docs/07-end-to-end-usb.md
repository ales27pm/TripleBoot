# End-to-end TripleBoot USB

The TripleBoot USB workflow turns one removable disk into a Ventoy-based installer
and recovery kit for the whole project. It does not hide destructive operations:
the selected USB is erased, every erase still requires `--yes-destroy`, and the
script asks for a typed confirmation before writing to the device.

## What the USB contains

| Path | Purpose |
|---|---|
| `/ISO/Ubuntu/` | Ubuntu installer ISO downloaded and verified from Ubuntu SHA256SUMS. |
| `/ISO/Windows/` | Windows installer ISO staged from an official Microsoft download or local file. |
| `/EFI/OPENCORE/` | Optional OpenCore EFI payload for manual review and removable-media testing. |
| `/macOS/OSX-KVM/` | Optional Linux-hosted macOS VM/recovery workflow assets. |
| `/TripleBoot/README-FIRST.txt` | Generated first-read safety note. |
| `/TripleBoot/QUICKSTART.md` | Generated boot and installation checklist. |
| `/TripleBoot/MANIFEST.json` | Machine-readable record of staged payloads and warnings. |
| `/TripleBoot/SHA256SUMS` | Hashes for staged files so the USB can be audited later. |
| `/TripleBoot/repo/` | Offline copy of this repository's scripts and documentation. |
| `/ventoy/ventoy.json` | Ventoy menu aliases and basic menu defaults. |

## Preflight

Install dependencies and inspect the host before building media:

```bash
sudo scripts/tripleboot_aio.sh install-deps
sudo scripts/tripleboot_aio.sh installer-doctor
sudo scripts/tripleboot_aio.sh usb-plan --include-opencore
```

Identify the USB disk with `lsblk`. Use the whole disk, such as `/dev/sdX`, not a
partition such as `/dev/sdX1`.

## One-command build

Use an existing Windows ISO:

```bash
sudo scripts/tripleboot_aio.sh build-tripleboot-usb \
  --usb-disk /dev/sdX \
  --windows-iso ~/Downloads/Windows11.iso \
  --ubuntu-version 26.04 \
  --include-opencore \
  --yes-destroy
```

Or provide a temporary Microsoft ISO URL:

```bash
sudo scripts/tripleboot_aio.sh build-tripleboot-usb \
  --usb-disk /dev/sdX \
  --windows-iso-url 'https://software.download.prss.microsoft.com/...' \
  --ubuntu-version 26.04 \
  --include-opencore \
  --yes-destroy
```

Add `--include-osx-kvm` if you want the USB to carry OSX-KVM recovery assets. This
is not an official Apple bootable installer; official full macOS USB creation still
requires macOS and `createinstallmedia`.

## Reusing existing payloads

If you have already built OpenCore, pass it explicitly:

```bash
sudo scripts/tripleboot_aio.sh stage-tripleboot-usb \
  --usb-disk /dev/sdX \
  --ubuntu-iso ~/tripleboot-aio/downloads/installers/ubuntu/ubuntu-26.04-desktop-amd64.iso \
  --windows-iso ~/tripleboot-aio/downloads/installers/windows/Windows11.iso \
  --opencore-efi ~/tripleboot-aio/build/EFI
```

## Verify the finished USB

```bash
sudo scripts/tripleboot_aio.sh tripleboot-usb-status --usb-disk /dev/sdX
```

From a mounted USB, verify staged file hashes:

```bash
cd /media/$USER/Ventoy
sha256sum -c TripleBoot/SHA256SUMS
```

## Installation flow from the USB

1. Boot the USB in UEFI mode.
2. Start the Ubuntu installer from Ventoy and install Ubuntu to the Ubuntu disk.
3. Start the Windows installer from Ventoy and install Windows to the Windows target.
4. Boot Linux again and run `scan`, `boot-report`, and `backup-efi`.
5. Test OpenCore only from removable media or a known-good copied EFI payload.
6. Do not copy OpenCore to an internal ESP until `ocvalidate` and hardware-specific
   review pass.
