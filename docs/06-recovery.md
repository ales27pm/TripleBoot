# Recovery

## EFI backup

Before changing boot files or boot order:

```bash
sudo scripts/tripleboot_aio.sh backup-efi
```

Backups are stored under:

```text
~/tripleboot-aio/backups/
```

or under `TRIPLEBOOT_BACKUP_ROOT` if configured.

## Restore EFI files

```bash
sudo scripts/tripleboot_aio.sh restore-efi \
  --backup-dir ~/tripleboot-aio/backups/efi-YYYYMMDD-HHMMSS/_dev_nvme0n1p1 \
  --esp /dev/nvme0n1p1 \
  --yes-destroy
```

This overwrites files on the target ESP from the backup directory.

## Recover Ubuntu boot

Boot Ubuntu live USB, mount the installed system, chroot, reinstall GRUB.

Sketch:

```bash
sudo mount /dev/nvme0n1p2 /mnt
sudo mount /dev/nvme0n1p1 /mnt/boot/efi
sudo mount --bind /dev /mnt/dev
sudo mount --bind /proc /mnt/proc
sudo mount --bind /sys /mnt/sys
sudo chroot /mnt
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
update-grub
exit
```

Adjust partition names to your actual disk.

## Recover Windows boot

Boot Windows recovery media, then use:

```text
bcdboot C:\Windows /f UEFI
```

Depending on drive letters inside recovery, `C:` may be different.

## Recover OpenCore

Use the OpenCore USB. Do not assume internal EFI is valid. Rebuild scaffold, validate, then copy only after confirming the USB path boots.
