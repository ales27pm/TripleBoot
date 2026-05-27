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

## Why `Sample.plist` matters

OpenCore changes over time. Starting from the matching `Sample.plist` and validating with the same release's `ocvalidate` reduces drift between config format and bootloader version.

## GPU boot arg

For NVIDIA RTX/Turing systems, `--gpu-policy disable-nvidia` adds:

```text
-wegnoegpu
```

This can help prevent unsupported NVIDIA GPUs from being initialized through WhateverGreen, but it does not make the RTX card supported by macOS.
