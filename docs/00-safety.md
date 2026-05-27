# Safety

TripleBoot is designed as a guarded helper, not a blind OS installer.

## Hard rules

1. Boot all installers in UEFI mode.
2. Use GPT partition tables only.
3. Back up EFI System Partitions before changing boot files.
4. Suspend BitLocker or back up the recovery key before editing ESP contents or UEFI boot order.
5. Do not share swap across operating systems.
6. Test OpenCore from USB before copying it to an internal EFI partition.
7. Never assume a generated OpenCore `config.plist` is final.

## Destructive commands

The `partition`, `make-usb`, and `restore-efi` commands are destructive. They require explicit flags and typed confirmations.

Example:

```bash
sudo scripts/tripleboot_aio.sh partition \
  --ubuntu-disk /dev/nvme0n1 \
  --winmac-disk /dev/nvme1n1 \
  --yes-destroy
```

The script also checks whether a selected disk appears to be the currently running root disk and refuses by default.

## Recovery kit

Keep these ready before running destructive operations:

- Ubuntu live USB
- Windows installer/recovery USB
- OpenCore USB
- EFI backup directory
- BitLocker recovery key if Windows uses BitLocker
- External backup of personal files

## macOS/OpenCore legal and technical scope

This project does not include macOS installer files, Apple firmware, Apple binaries, or serials. It builds an OpenCore scaffold from public OpenCore/kext releases and leaves hardware-specific configuration to manual review.
