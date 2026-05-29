# TripleBoot State

## Project identity

TripleBoot is a guarded automation and documentation repository for a UEFI/GPT workstation triple boot:

- Ubuntu Linux
- Windows 10/11
- macOS/OpenCore experiments on compatible x86 hardware

## Current target assumptions

- Owner/handle: `ales27pm`
- Repository: `ales27pm/TripleBoot`
- Preferred layout: two physical disks
- Disk A: Ubuntu owns the disk
- Disk B: Windows + macOS placeholder
- Windows target size: 500 GiB by default
- Ubuntu swap strategy: swapfile, not shared partition
- Boot strategy: native UEFI entries, optional rEFInd, OpenCore from USB first

## Known hardware risk

The discussed machine includes an NVIDIA RTX 2070. This is treated as a blocker for usable macOS hardware acceleration. The default OpenCore scaffold therefore supports `--gpu-policy disable-nvidia`, but this is only a boot-time mitigation and does not make RTX/Turing supported by macOS.

## Safety position

The project must never behave like a blind installer. Destructive operations require explicit flags and typed confirmations. The script refuses to partition the running root disk unless `--force` is passed. EFI backup is part of the expected workflow before bootloader changes.

## Generated assets

- `scripts/tripleboot_aio.sh`: main AIO script
- `scripts/hackintosh-opencore-prepare.sh`: standalone Linux OpenCore recovery workspace/USB preparer
- `docs/`: operational documentation
- `examples/tripleboot.env.example`: environment configuration example
- `.github/workflows/shellcheck.yml`: shell lint CI

## Next planned improvements

- Add fixture-based tests for disk naming, especially NVMe `p1` partition suffix handling.
- Add JSON schema for scan inventory output.
- Add optional local dry-run test harness using loopback disks.
- Add OpenCore config fragment generator modules instead of one monolithic Bash implementation.
- Add docs for supported AMD GPU candidates and iGPU limitations.
