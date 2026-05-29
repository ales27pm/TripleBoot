# OpenCore Notes

OpenCore is the bootloader layer used for macOS experiments. This repository does not generate a final machine-perfect OpenCore EFI. It generates a guarded scaffold and review checklist.

## What the script can automate

- Download latest OpenCore release archive.
- Download common kext release archives.
- Create `EFI/BOOT` and `EFI/OC` structure.
- Copy `OpenCore.efi`, `BOOTx64.efi`, basic drivers and tools.
- Copy downloaded kext bundles.
- Generate a `config.plist` from `Sample.plist` when available.
- Add basic boot args and optional `-wegnoegpu` when `--gpu-policy disable-nvidia` is selected.
- Run `ocvalidate` if available.

## What must be reviewed manually

- Platform-specific SSDTs.
- SMBIOS choice.
- Serial number, MLB, SystemUUID, ROM.
- iGPU framebuffer/device properties.
- Audio `layout-id`.
- USB map.
- Wi-Fi/Bluetooth strategy.
- NVRAM/secure boot model.

## Recommended commands

```bash
sudo scripts/tripleboot_aio.sh download-opencore
sudo scripts/tripleboot_aio.sh download-kexts
sudo scripts/tripleboot_aio.sh build-opencore-scaffold \
  --gpu-policy disable-nvidia \
  --smbios iMac20,1
sudo scripts/tripleboot_aio.sh validate-opencore
```


## Standalone Linux recovery workspace script

If you want a focused Linux-only OpenCore recovery workspace outside the full TripleBoot AIO flow, use:

```bash
chmod +x scripts/hackintosh-opencore-prepare.sh
scripts/hackintosh-opencore-prepare.sh --macos sequoia --workdir "$HOME/hackintosh"
```

To destructively format and stage a USB disk, add `--disk` and run with root privileges after verifying the target disk name:

```bash
sudo scripts/hackintosh-opencore-prepare.sh --macos sequoia --disk /dev/sdX --workdir "$HOME/hackintosh"
```

Supported recovery choices are `ventura`, `sonoma`, `sequoia`, and `tahoe`. The script intentionally copies OpenCore's sample config as a starting point only; hardware-specific ACPI, SMBIOS, USB mapping, audio layout, and GPU configuration still require manual review.

## Why `Sample.plist` matters

OpenCore changes over time. Starting from the matching `Sample.plist` and validating with the same release's `ocvalidate` reduces drift between config format and bootloader version.

## GPU boot arg

For NVIDIA RTX/Turing systems, `--gpu-policy disable-nvidia` adds:

```text
-wegnoegpu
```

This can help prevent unsupported NVIDIA GPUs from being initialized through WhateverGreen, but it does not make the RTX card supported by macOS.
