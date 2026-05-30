#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC2312
# TripleBoot AIO — guarded UEFI/GPT helper for Ubuntu + Windows + OpenCore/macOS experiments.
# It automates only the safe/repeatable parts: scan, report, EFI backup, two-disk partitioning,
# swapfile setup, OpenCore scaffold download/generation, validation hooks, and USB EFI creation.
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2026.05.30"
WORKDIR="${TRIPLEBOOT_WORKDIR:-$HOME/tripleboot-aio}"
BACKUP_ROOT="${TRIPLEBOOT_BACKUP_ROOT:-$WORKDIR/backups}"
INVENTORY_DIR="${TRIPLEBOOT_INVENTORY_DIR:-$WORKDIR/inventory}"
BUILD_DIR="${TRIPLEBOOT_BUILD_DIR:-$WORKDIR/build}"
DOWNLOAD_DIR="${TRIPLEBOOT_DOWNLOAD_DIR:-$WORKDIR/downloads}"
LOG_DIR="${TRIPLEBOOT_LOG_DIR:-$WORKDIR/logs}"
EFI_SIZE="${EFI_SIZE:-1024MiB}"
WINDOWS_SIZE="${WINDOWS_SIZE:-500GiB}"
UBUNTU_SWAP_SIZE="${UBUNTU_SWAP_SIZE:-32G}"
DRY_RUN=false
FORCE=false
NONINTERACTIVE=false
YES_DESTROY=false
SHOW_BANNER=true
APT_DEPS=(
  bash coreutils util-linux gawk sed grep findutils file jq curl wget unzip zip git rsync
  gdisk parted dosfstools e2fsprogs ntfs-3g efibootmgr mokutil pciutils usbutils dmidecode
  lshw hwinfo acpica-tools fwupd nvme-cli qemu-utils qemu-system-x86 ovmf python3 python3-pip
  alsa-utils shellcheck wimtools uml-utilities virt-manager libguestfs-tools p7zip-full make dmg2img tesseract-ocr tesseract-ocr-eng genisoimage net-tools screen
)

if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  MAGENTA=$'\033[35m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  MAGENTA=""
  BOLD=""
  RESET=""
fi

mkdir -p "$WORKDIR" "$BACKUP_ROOT" "$INVENTORY_DIR" "$BUILD_DIR" "$DOWNLOAD_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/tripleboot-$(date +%Y%m%d-%H%M%S).log"

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*" >> "$LOG_FILE"; }
info() { printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; log "INFO $*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; log "WARN $*"; }
die() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; log "ERROR $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run with sudo/root."; }
is_uefi() { [[ -d /sys/firmware/efi ]]; }
assert_uefi() { is_uefi || die "System is not booted in UEFI mode. Reboot installer/live USB in UEFI mode."; }
require() { have "$1" || die "Missing command: $1"; }

run() {
  log "RUN $*"
  if [[ "$DRY_RUN" == true ]]; then
    printf '%s[DRY-RUN]%s %s\n' "$BLUE" "$RESET" "$*"
  else
    "$@"
  fi
}

ui_section() {
  printf '\n%s==>%s %s\n' "$MAGENTA" "$RESET" "$*"
  log "SECTION $*"
}

tripleboot_banner() {
  [[ "$SHOW_BANNER" == true ]] || return 0
  cat <<'BANNER'
████████╗██████╗ ██╗██████╗ ██╗     ███████╗██████╗  ██████╗  ██████╗ ████████╗
╚══██╔══╝██╔══██╗██║██╔══██╗██║     ██╔════╝██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝
   ██║   ██████╔╝██║██████╔╝██║     █████╗  ██████╔╝██║   ██║██║   ██║   ██║
   ██║   ██╔══██╗██║██╔═══╝ ██║     ██╔══╝  ██╔══██╗██║   ██║██║   ██║   ██║
   ██║   ██║  ██║██║██║     ███████╗███████╗██████╔╝╚██████╔╝╚██████╔╝   ██║
   ╚═╝   ╚═╝  ╚═╝╚═╝╚═╝     ╚══════╝╚══════╝╚═════╝  ╚═════╝  ╚═════╝    ╚═╝
    UEFI / GPT / OpenCore Lab Assistant  ::  PLAN • SCAN • ANALYZE • SAFEGUARD
BANNER
}

confirm() {
  local token="$1" msg="$2" answer
  [[ "$NONINTERACTIVE" == true ]] && die "Confirmation required but --noninteractive is set: $msg"
  printf '%s\nType %s to continue: ' "$msg" "$token"
  read -r answer
  [[ "$answer" == "$token" ]] || die "Aborted."
}

part_name() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$num"
  else
    printf '%s%s\n' "$disk" "$num"
  fi
}

root_parent_disk() {
  local src pk
  src="$(findmnt -n -o SOURCE / || true)"
  [[ "$src" == /dev/* ]] || return 0
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
  [[ -n "$pk" ]] && printf '/dev/%s\n' "$pk"
}

assert_disk() {
  local disk="$1" typ
  [[ -b "$disk" ]] || die "Block device not found: $disk"
  typ="$(lsblk -dn -o TYPE "$disk" 2>/dev/null || true)"
  [[ "$typ" == "disk" ]] || die "$disk is not a whole disk. Use /dev/nvme0n1, not a partition."
}

protect_running_root() {
  local target="$1" rootdisk
  rootdisk="$(root_parent_disk || true)"
  if [[ -n "$rootdisk" && "$target" == "$rootdisk" && "$FORCE" != true ]]; then
    die "Refusing to partition the running root disk: $target. Boot from a live USB or pass --force only if intentional."
  fi
}

unmount_disk() {
  local disk="$1" part mountpoint
  while read -r part; do
    [[ -n "$part" ]] || continue
    while read -r mountpoint; do
      if [[ -n "$mountpoint" ]]; then
        run umount "$mountpoint" || true
      fi
    done < <(lsblk -lnpo MOUNTPOINTS "$part" 2>/dev/null | tr ' ' '\n' | sed '/^$/d')
  done < <(lsblk -lnpo NAME "$disk" | tail -n +2 || true)
}

usage() {
  tripleboot_banner
  cat <<EOF_USAGE
${BOLD}TripleBoot AIO v$VERSION${RESET}

Commands:
  plan
  install-deps
  install-refind
  scan
  analyze
  doctor
  preflight-partition --ubuntu-disk DISK --winmac-disk DISK [--allow-wipe-data-on DISK]
  installer-doctor
  download-ubuntu [--version 26.04] [--edition desktop|server] [--arch amd64]
  verify-iso-sha256 --iso FILE --sha256-file FILE
  download-windows --iso-url URL | --iso-file FILE [--output-name NAME]
  prepare-usb-dd --usb-disk DISK --iso FILE --yes-destroy
  prepare-usb-ubuntu --usb-disk DISK --iso FILE --yes-destroy
  prepare-usb-windows --usb-disk DISK --iso FILE --yes-destroy
  download-macos [--version VERSION]
  prepare-usb-macos --volume-name NAME [--app-path PATH]
  osx-kvm-doctor
  osx-kvm-clone [--dir DIR]
  osx-kvm-fetch [--dir DIR]
  osx-kvm-convert [--dir DIR]
  osx-kvm-create-disk [--dir DIR] [--size 256G]
  osx-kvm-boot [--dir DIR]
  osx-kvm-offline-iso --pkg FILE [--dir DIR]
  download-ventoy [--version latest]
  prepare-usb-ventoy --usb-disk DISK --yes-destroy
  usb-plan [--include-osx-kvm] [--include-opencore]
  stage-tripleboot-usb --usb-disk DISK [--ubuntu-iso FILE] [--windows-iso FILE] [--osx-kvm-dir DIR] [--opencore-efi DIR]
  build-tripleboot-usb --usb-disk DISK --windows-iso FILE|--windows-iso-url URL [--ubuntu-version 26.04] [--include-osx-kvm] [--include-opencore] --yes-destroy
  tripleboot-usb-status --usb-disk DISK
  backup-efi
  boot-report
  partition --ubuntu-disk DISK --winmac-disk DISK --yes-destroy
  setup-swap [--size 32G] [--file /swapfile]
  download-opencore [--version latest]
  download-kexts
  build-opencore-scaffold [--oc-zip PATH] [--smbios iMac20,1] [--gpu-policy disable-nvidia|none]
  validate-opencore
  make-usb --usb-disk DISK --yes-destroy
  restore-efi --backup-dir DIR --esp PARTITION --yes-destroy

Global flags:
  --dry-run
  --force
  --noninteractive
  --no-banner

Default layout:
  Disk A: 1 GiB EFI + rest Ubuntu ext4.
  Disk B: 1 GiB EFI + 16 MiB MSR + $WINDOWS_SIZE Windows NTFS + rest macOS APFS placeholder.
EOF_USAGE
}

plan() {
  tripleboot_banner
  cat <<EOF_PLAN
TripleBoot plan

1. UEFI/GPT only.
2. Disk A: Ubuntu owns the disk.
   - EFI FAT32: 1 GiB, label UBUNTU_EFI
   - Root ext4: rest, label UBUNTU_ROOT
   - Swap: /swapfile, default $UBUNTU_SWAP_SIZE
3. Disk B: Windows + macOS/OpenCore experiment.
   - EFI FAT32: 1 GiB, label WINMAC_EFI
   - MSR: 16 MiB
   - Windows NTFS: $WINDOWS_SIZE, label WINDOWS
   - macOS placeholder: rest, type Apple APFS, label MACOS_APFS
4. Bootloaders:
   - Windows Boot Manager: EFI/Microsoft
   - Ubuntu GRUB: EFI/ubuntu
   - OpenCore: EFI/OC
   - Optional rEFInd selector.
5. RTX 2070 warning:
   - NVIDIA RTX/Turing is not a macOS acceleration path.
   - Use supported iGPU/AMD for bare metal or treat macOS as VM/lab only.
6. Never share swap across OSes.
7. Backup ESPs before changing boot files or boot order.
EOF_PLAN
}

install_deps() {
  ui_section "Installing dependencies"
  need_root
  have apt-get || die "Only apt-based systems are automated here."
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update
  run apt-get install -y "${APT_DEPS[@]}"
}

install_refind() {
  ui_section "Installing rEFInd"
  need_root
  assert_uefi
  have apt-get || die "Only apt-based systems are automated here."
  export DEBIAN_FRONTEND=noninteractive
  warn "This command intentionally installs rEFInd and may create/change UEFI boot entries."
  confirm INSTALL_REFIND "Installing rEFInd can modify UEFI boot entries."
  run apt-get update
  run apt-get install -y refind
}

scan() {
  ui_section "Running hardware scan"
  need_root
  mkdir -p "$INVENTORY_DIR/raw" "$INVENTORY_DIR/parsed"
  local raw="$INVENTORY_DIR/raw"
  run bash -c "lscpu -J > '$raw/lscpu.json'" || true
  run bash -c "grep -i 'model name' /proc/cpuinfo | sort -u > '$raw/cpu_model.txt'" || true
  run bash -c "lspci -nnk > '$raw/lspci_nnk.txt'" || true
  run bash -c "lspci -tv > '$raw/lspci_tree.txt'" || true
  run bash -c "lsusb > '$raw/lsusb.txt'" || true
  run bash -c "lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,PTTYPE,PARTTYPENAME,PARTLABEL,PARTUUID,UUID,MOUNTPOINTS,MODEL,SERIAL --json > '$raw/lsblk.json'" || true
  run bash -c "dmidecode -t bios -t system -t baseboard -t processor > '$raw/dmidecode.txt'" || true
  run bash -c "efibootmgr -v > '$raw/efibootmgr.txt'" || true
  run bash -c "mokutil --sb-state > '$raw/mokutil.txt'" || true
  run bash -c "nvme list -o json > '$raw/nvme_list.json'" || true
  run bash -c "aplay -l > '$raw/aplay.txt'" || true
  if have acpidump; then
    mkdir -p "$raw/acpi"
    rm -f "$raw/acpi"/acpi.dump "$raw/acpi"/*.dat
    run bash -c "cd '$raw/acpi' && acpidump -b -o acpi.dump" || true
  fi
  python3 - "$raw" "$INVENTORY_DIR/parsed/inventory.json" <<'PY_SCAN'
import json, pathlib, re, sys, datetime
root = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2])
def text(name):
    p = root / name
    return p.read_text(errors='ignore') if p.exists() else ''
def lines(pattern, src):
    return [x.strip() for x in src.splitlines() if re.search(pattern, x, re.I)]
lspci = text('lspci_nnk.txt'); dmi = text('dmidecode.txt'); mok = text('mokutil.txt')
def dmi_field(section, key):
    active = False
    for ln in dmi.splitlines():
        if section.lower() in ln.lower(): active = True
        elif active and ln and not ln.startswith((' ', '\t')): active = False
        if active:
            m = re.match(r'\s*' + re.escape(key) + r':\s*(.*)', ln)
            if m: return m.group(1).strip()
    return None
gpus = lines(r'(VGA|3D|Display)', lspci)
inv = {
    'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'cpu_model': (text('cpu_model.txt').splitlines() or ['unknown'])[0],
    'motherboard': {'vendor': dmi_field('Base Board Information', 'Manufacturer'), 'product': dmi_field('Base Board Information', 'Product Name')},
    'bios': {'vendor': dmi_field('BIOS Information', 'Vendor'), 'version': dmi_field('BIOS Information', 'Version'), 'date': dmi_field('BIOS Information', 'Release Date')},
    'gpu_lines': gpus,
    'has_nvidia_rtx_turing_like': any(re.search(r'NVIDIA.*RTX|GeForce RTX|TU10|TU11|Turing', g, re.I) for g in gpus),
    'has_rtx_2070': any(re.search(r'RTX\s*2070', g, re.I) for g in gpus),
    'network_lines': lines(r'(Ethernet|Network|Wireless)', lspci),
    'audio_lines': lines(r'Audio', lspci),
    'booted_uefi': pathlib.Path('/sys/firmware/efi').exists(),
    'secure_boot': mok.strip(),
    'risk_flags': []
}
if inv['has_nvidia_rtx_turing_like']: inv['risk_flags'].append('NVIDIA_RTX_TURING_NOT_SUPPORTED_FOR_MACOS_ACCELERATION')
if not inv['booted_uefi']: inv['risk_flags'].append('NOT_BOOTED_IN_UEFI')
if 'enabled' in mok.lower(): inv['risk_flags'].append('SECURE_BOOT_ENABLED')
out.parent.mkdir(parents=True, exist_ok=True); out.write_text(json.dumps(inv, indent=2))
PY_SCAN
  info "Scan complete: $INVENTORY_DIR"
}

analyze() {
  ui_section "Building analysis report"
  local inv="$INVENTORY_DIR/parsed/inventory.json" report gpu_note risk_flags
  [[ -f "$inv" ]] || die "Run scan first."
  require jq
  report="$WORKDIR/TRIPLEBOOT_REPORT.md"
  risk_flags="$(jq -r '.risk_flags | join(", ")' "$inv")"
  if jq -e '.has_rtx_2070 or .has_nvidia_rtx_turing_like' "$inv" >/dev/null; then
    gpu_note='NVIDIA RTX/Turing detected. Treat macOS bare-metal acceleration as unsupported. Use iGPU/AMD or lab/VM mode.'
  else
    gpu_note='No RTX/Turing flag detected. Still verify GPU support manually.'
  fi
  cat > "$report" <<EOF_REPORT
# TripleBoot Analysis

Generated: $(date --iso-8601=seconds)

## Detected

- CPU: $(jq -r '.cpu_model' "$inv")
- Board: $(jq -r '(.motherboard.vendor // "unknown") + " " + (.motherboard.product // "unknown")' "$inv")
- UEFI booted: $(jq -r '.booted_uefi' "$inv")
- Secure Boot: $(jq -r '.secure_boot // "unknown"' "$inv")
- Risk flags: $risk_flags

## GPU

$gpu_note

## Next actions

1. Run backup-efi.
2. Confirm disk names with boot-report.
3. Partition only from a live USB or with full awareness of root disk protection.
4. Install Windows, then Ubuntu, then test OpenCore from USB first.
EOF_REPORT
  cat "$report"
}

detect_esps() {
  lsblk -rpno NAME,TYPE,FSTYPE,PARTTYPE,PARTLABEL,LABEL | awk '$2=="part" && (tolower($4) ~ /c12a7328/ || $3=="vfat" || $5 ~ /EFI/ || $6 ~ /EFI/) {print $1}' | sort -u
}

backup_efi() {
  need_root
  require rsync
  require mount
  require umount
  local dest esp mnt safe
  dest="$BACKUP_ROOT/efi-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dest"
  mapfile -t esps < <(detect_esps)
  [[ ${#esps[@]} -gt 0 ]] || die "No EFI partitions detected."
  for esp in "${esps[@]}"; do
    mnt="$(mktemp -d)"
    safe="$(printf '%s' "$esp" | sed 's#[/:]#_#g')"
    mkdir -p "$dest/$safe"
    local existing_mount=""
    existing_mount="$(findmnt -n -o TARGET --source "$esp" 2>/dev/null | head -n1 || true)"
    if [[ -n "$existing_mount" ]]; then
      run rsync -aHAX --numeric-ids "$existing_mount"/ "$dest/$safe"/
    elif run mount -o ro "$esp" "$mnt"; then
      run rsync -aHAX --numeric-ids "$mnt"/ "$dest/$safe"/
      run umount "$mnt"
    fi
    rmdir "$mnt" || true
  done
  info "EFI backup: $dest"
}

boot_report() {
  need_root
  echo "=== UEFI ==="
  is_uefi && echo yes || echo no
  if have mokutil; then
    mokutil --sb-state || true
  fi
  echo
  echo "=== Disks ==="
  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,PTTYPE,PARTTYPENAME,PARTLABEL,LABEL,MOUNTPOINTS,MODEL
  echo
  echo "=== Boot entries ==="
  if have efibootmgr; then
    efibootmgr -v || true
  fi
  echo
  echo "=== EFI loaders ==="
  local esp mnt
  mapfile -t esps < <(detect_esps)
  for esp in "${esps[@]:-}"; do
    mnt="$(mktemp -d)"
    echo "--- $esp ---"
    local existing_mount=""
    existing_mount="$(findmnt -n -o TARGET --source "$esp" 2>/dev/null | head -n1 || true)"
    if [[ -n "$existing_mount" ]]; then
      find "$existing_mount" -maxdepth 6 -type f -iname '*.efi' | sed "s#^$existing_mount##" | sort
    elif mount -o ro "$esp" "$mnt"; then
      find "$mnt" -maxdepth 6 -type f -iname '*.efi' | sed "s#^$mnt##" | sort
      umount "$mnt"
    fi
    rmdir "$mnt" || true
  done
}

partition_cmd() {
  need_root
  assert_uefi
  require sgdisk
  require wipefs
  require partprobe
  require mkfs.vfat
  require mkfs.ext4
  local ubuntu="" winmac=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ubuntu-disk) ubuntu="$2"; shift 2 ;;
      --winmac-disk) winmac="$2"; shift 2 ;;
      --yes-destroy) YES_DESTROY=true; shift ;;
      *) die "Unknown partition arg: $1" ;;
    esac
  done
  [[ -n "$ubuntu" && -n "$winmac" ]] || die "Both --ubuntu-disk and --winmac-disk are required."
  [[ "$ubuntu" != "$winmac" ]] || die "Disks must be different."
  assert_disk "$ubuntu"
  assert_disk "$winmac"
  protect_running_root "$ubuntu"
  protect_running_root "$winmac"
  [[ "$YES_DESTROY" == true ]] || die "Add --yes-destroy for destructive partitioning."
  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,LABEL,MOUNTPOINTS,MODEL
  confirm DESTROY "This will wipe $ubuntu and $winmac."

  unmount_disk "$ubuntu"
  run sgdisk --zap-all "$ubuntu"
  run wipefs -af "$ubuntu"
  run partprobe "$ubuntu"
  sleep 2
  run sgdisk -n 1:1MiB:+"$EFI_SIZE" -t 1:EF00 -c 1:UBUNTU_EFI -n 2:0:0 -t 2:8304 -c 2:UBUNTU_ROOT "$ubuntu"
  run partprobe "$ubuntu"
  sleep 2
  run mkfs.vfat -F32 -n UBUNTU_EFI "$(part_name "$ubuntu" 1)"
  run mkfs.ext4 -F -L UBUNTU_ROOT "$(part_name "$ubuntu" 2)"

  unmount_disk "$winmac"
  run sgdisk --zap-all "$winmac"
  run wipefs -af "$winmac"
  run partprobe "$winmac"
  sleep 2
  run sgdisk -n 1:1MiB:+"$EFI_SIZE" -t 1:EF00 -c 1:WINMAC_EFI -n 2:0:+16MiB -t 2:0C01 -c 2:MSR -n 3:0:+"$WINDOWS_SIZE" -t 3:0700 -c 3:WINDOWS -n 4:0:0 -t 4:AF0A -c 4:MACOS_APFS "$winmac"
  run partprobe "$winmac"
  sleep 2
  run mkfs.vfat -F32 -n WINMAC_EFI "$(part_name "$winmac" 1)"
  if have mkfs.ntfs; then
    run mkfs.ntfs -f -L WINDOWS "$(part_name "$winmac" 3)"
  else
    warn "mkfs.ntfs missing; Windows installer can format partition 3."
  fi
  warn "macOS/APFS placeholder is intentionally unformatted."
}

setup_swap() {
  need_root
  require mkswap
  require swapon
  local size="$UBUNTU_SWAP_SIZE" file="/swapfile"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --size) size="$2"; shift 2 ;;
      --file) file="$2"; shift 2 ;;
      *) die "Unknown setup-swap arg: $1" ;;
    esac
  done
  run swapoff "$file" 2>/dev/null || true
  if have fallocate; then
    run fallocate -l "$size" "$file"
  else
    run dd if=/dev/zero of="$file" bs=1M count=32768 status=progress
  fi
  run chmod 600 "$file"
  run mkswap "$file"
  run swapon "$file"
  grep -q "^$file " /etc/fstab || echo "$file none swap sw 0 0" >> /etc/fstab
  swapon --show
}

github_latest_asset_url() {
  local repo="$1" regex="$2"
  require curl
  require jq
  curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | jq -r --arg re "$regex" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1
}

download_url() {
  local url="$1" out="$2"
  [[ -n "$url" && "$url" != null ]] || die "Empty URL"
  mkdir -p "$(dirname "$out")"
  [[ -f "$out" ]] || run curl -L --fail --retry 3 -o "$out" "$url"
}

download_opencore() {
  local version="latest" url out
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      *) die "Unknown download-opencore arg: $1" ;;
    esac
  done
  if [[ "$version" == latest ]]; then
    url="$(github_latest_asset_url acidanthera/OpenCorePkg 'RELEASE.*\.zip$|OpenCore.*RELEASE.*\.zip$')"
    out="$DOWNLOAD_DIR/opencore-latest.zip"
  else
    url="https://github.com/acidanthera/OpenCorePkg/releases/download/${version}/OpenCore-${version}-RELEASE.zip"
    out="$DOWNLOAD_DIR/opencore-${version}.zip"
  fi
  download_url "$url" "$out"
  info "OpenCore: $out"
}

download_kexts() {
  mkdir -p "$DOWNLOAD_DIR/kexts"
  local specs=(
    "acidanthera/Lilu:Lilu.*RELEASE.*\.zip$"
    "acidanthera/VirtualSMC:VirtualSMC.*RELEASE.*\.zip$"
    "acidanthera/WhateverGreen:WhateverGreen.*RELEASE.*\.zip$"
    "acidanthera/AppleALC:AppleALC.*RELEASE.*\.zip$"
    "acidanthera/IntelMausi:IntelMausi.*RELEASE.*\.zip$"
    "acidanthera/NVMeFix:NVMeFix.*RELEASE.*\.zip$"
  )
  local spec repo regex name url
  for spec in "${specs[@]}"; do
    repo="${spec%%:*}"
    regex="${spec#*:}"
    name="${repo##*/}"
    url="$(github_latest_asset_url "$repo" "$regex" || true)"
    if [[ -n "$url" ]]; then
      download_url "$url" "$DOWNLOAD_DIR/kexts/$name.zip"
    else
      warn "No asset for $repo"
    fi
  done
}

extract_zip() {
  rm -rf "$2"
  mkdir -p "$2"
  run unzip -q "$1" -d "$2"
}

build_opencore_scaffold() {
  local oc_zip="" smbios="iMac20,1" gpu_policy="none"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --oc-zip) oc_zip="$2"; shift 2 ;;
      --smbios) smbios="$2"; shift 2 ;;
      --gpu-policy) gpu_policy="$2"; shift 2 ;;
      *) die "Unknown build arg: $1" ;;
    esac
  done
  [[ -n "$oc_zip" ]] || oc_zip="$DOWNLOAD_DIR/opencore-latest.zip"
  [[ -f "$oc_zip" ]] || die "OpenCore zip not found. Run download-opencore."
  rm -rf "$BUILD_DIR/ocpkg" "$BUILD_DIR/EFI"
  mkdir -p "$BUILD_DIR/EFI/BOOT" "$BUILD_DIR/EFI/OC"/{ACPI,Drivers,Kexts,Tools,Resources}
  extract_zip "$oc_zip" "$BUILD_DIR/ocpkg"
  local ocroot bootroot sample zip_path tmp_dir
  ocroot="$(find "$BUILD_DIR/ocpkg" -type d -path '*/X64/EFI/OC' | head -n1 || true)"
  [[ -n "$ocroot" ]] || die "Cannot find X64/EFI/OC."
  bootroot="${ocroot%/OC}/BOOT"
  cp -a "$bootroot/BOOTx64.efi" "$BUILD_DIR/EFI/BOOT/"
  cp -a "$ocroot/OpenCore.efi" "$BUILD_DIR/EFI/OC/"
  cp -a "$ocroot/Drivers/OpenRuntime.efi" "$BUILD_DIR/EFI/OC/Drivers/" 2>/dev/null || true
  cp -a "$ocroot/Drivers/OpenHfsPlus.efi" "$BUILD_DIR/EFI/OC/Drivers/" 2>/dev/null || true
  cp -a "$ocroot/Tools/ResetNvramEntry.efi" "$BUILD_DIR/EFI/OC/Tools/" 2>/dev/null || true
  cp -a "$ocroot/Tools/OpenShell.efi" "$BUILD_DIR/EFI/OC/Tools/" 2>/dev/null || true
  for zip_path in "$DOWNLOAD_DIR"/kexts/*.zip; do
    [[ -f "$zip_path" ]] || continue
    tmp_dir="$BUILD_DIR/kexttmp/$(basename "$zip_path" .zip)"
    extract_zip "$zip_path" "$tmp_dir"
    find "$tmp_dir" -maxdepth 8 -type d -name '*.kext' ! -path '*Debug*' -exec cp -a {} "$BUILD_DIR/EFI/OC/Kexts/" \;
  done
  sample="$(find "$BUILD_DIR/ocpkg" -type f -name Sample.plist | head -n1 || true)"
  [[ -n "$sample" ]] && cp "$sample" "$BUILD_DIR/Sample.plist"
  python3 - "$BUILD_DIR" "$smbios" "$gpu_policy" <<'PY_OC'
import plistlib, pathlib, sys, uuid
build = pathlib.Path(sys.argv[1]); smbios = sys.argv[2]; gpu = sys.argv[3]
sample = build / 'Sample.plist'; out = build / 'EFI/OC/config.plist'
if sample.exists():
    cfg = plistlib.load(sample.open('rb'))
else:
    cfg = {'ACPI': {'Add': []}, 'Kernel': {'Add': []}, 'UEFI': {'Drivers': []}, 'Misc': {'Security': {}, 'Tools': []}, 'NVRAM': {'Add': {}}, 'PlatformInfo': {'Generic': {}}, 'DeviceProperties': {'Add': {}, 'Delete': {}}}
def ensure(*keys):
    cur = cfg
    for key in keys:
        cur = cur.setdefault(key, {})
    return cur
def kext_executable(kext):
    exe_dir = kext / 'Contents/MacOS'
    if exe_dir.exists():
        entries = sorted(exe_dir.iterdir())
        if entries:
            return 'Contents/MacOS/' + entries[0].name
    return ''
cfg.setdefault('Kernel', {})['Add'] = [{'Arch': 'Any', 'BundlePath': p.name, 'Comment': p.name, 'Enabled': True, 'ExecutablePath': kext_executable(p), 'MaxKernel': '', 'MinKernel': '', 'PlistPath': 'Contents/Info.plist'} for p in sorted((build / 'EFI/OC/Kexts').glob('*.kext'))]
cfg.setdefault('UEFI', {})['Drivers'] = [{'Arguments': '', 'Comment': p.name, 'Enabled': True, 'LoadEarly': False, 'Path': p.name} for p in sorted((build / 'EFI/OC/Drivers').glob('*.efi'))]
sec = ensure('Misc', 'Security'); sec['Vault'] = 'Optional'; sec['ScanPolicy'] = 0; sec['SecureBootModel'] = 'Disabled'
nv = ensure('NVRAM', 'Add').setdefault('7C436110-AB2A-4BBB-A880-FE41995C9F82', {})
args = '-v keepsyms=1 debug=0x100' + (' -wegnoegpu' if gpu == 'disable-nvidia' else '')
nv['boot-args'] = args; nv['prev-lang:kbd'] = 'fr-CA:0'
pi = ensure('PlatformInfo', 'Generic'); pi['SystemProductName'] = smbios; pi.setdefault('SystemUUID', str(uuid.uuid4()).upper()); pi.setdefault('SystemSerialNumber', 'REPLACE_WITH_VALID_SERIAL'); pi.setdefault('MLB', 'REPLACE_WITH_VALID_MLB'); pi.setdefault('ROM', b'\0' * 6)
out.parent.mkdir(parents=True, exist_ok=True); plistlib.dump(cfg, out.open('wb'), sort_keys=False)
PY_OC
  cat > "$BUILD_DIR/manual-review-checklist.md" <<EOF_CHECKLIST
# OpenCore manual review

- SMBIOS candidate: $smbios
- GPU policy: $gpu_policy
- Config: $BUILD_DIR/EFI/OC/config.plist

Before booting bare metal:
- Confirm CPU generation and Dortania page.
- Confirm GPU path. RTX/Turing is not a macOS acceleration path.
- Add platform SSDTs: PLUG, EC/USBX, AWAC/RTC, PMC/RHUB as required.
- Generate real serial, MLB, UUID, ROM.
- Validate using ocvalidate from the same OpenCore release.
- Complete USB map and audio layout-id.
EOF_CHECKLIST
  info "OpenCore scaffold: $BUILD_DIR/EFI"
}

validate_opencore() {
  local cfg="$BUILD_DIR/EFI/OC/config.plist" validator
  [[ -f "$cfg" ]] || die "Missing $cfg"
  validator="$(find "$BUILD_DIR/ocpkg" -type f -name ocvalidate 2>/dev/null | head -n1 || true)"
  [[ -n "$validator" ]] || die "ocvalidate not found. Build scaffold first."
  chmod +x "$validator"
  run "$validator" "$cfg"
}

make_usb() {
  need_root
  assert_uefi
  local usb=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --usb-disk) usb="$2"; shift 2 ;;
      --yes-destroy) YES_DESTROY=true; shift ;;
      *) die "Unknown make-usb arg: $1" ;;
    esac
  done
  assert_disk "$usb"
  [[ -d "$BUILD_DIR/EFI" ]] || die "Build OpenCore scaffold first."
  [[ "$YES_DESTROY" == true ]] || die "Add --yes-destroy."
  confirm WIPEUSB "This will wipe USB disk $usb."
  unmount_disk "$usb"
  run sgdisk --zap-all "$usb"
  run wipefs -af "$usb"
  run sgdisk -n 1:1MiB:0 -t 1:0700 -c 1:OPENCORE_USB "$usb"
  run partprobe "$usb"
  sleep 2
  local part mount_dir
  part="$(part_name "$usb" 1)"
  run mkfs.vfat -F32 -n OPENCORE "$part"
  mount_dir="$(mktemp -d)"
  run mount "$part" "$mount_dir"
  run rsync -aHAX "$BUILD_DIR/EFI" "$mount_dir"/
  sync
  run umount "$mount_dir"
  rmdir "$mount_dir" || true
}

restore_efi() {
  need_root
  require rsync
  local backup="" esp=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backup-dir) backup="$2"; shift 2 ;;
      --esp) esp="$2"; shift 2 ;;
      --yes-destroy) YES_DESTROY=true; shift ;;
      *) die "Unknown restore arg: $1" ;;
    esac
  done
  [[ -d "$backup" && -b "$esp" ]] || die "Need --backup-dir DIR and --esp PARTITION"
  [[ "$YES_DESTROY" == true ]] || die "Add --yes-destroy."
  confirm RESTORE "This will overwrite files on $esp from $backup."
  local mount_dir
  mount_dir="$(mktemp -d)"
  run mount "$esp" "$mount_dir"
  run rsync -aHAX --delete "$backup"/ "$mount_dir"/
  sync
  run umount "$mount_dir"
  rmdir "$mount_dir" || true
}




installer_doctor() {
  ui_section "Installer factory doctor"

  local host_os=""
  local required_common=(curl sha256sum lsblk find awk sed grep python3)
  local required_usb=(sgdisk wipefs partprobe mkfs.vfat mount umount rsync)
  local cmd=""

  host_os="$(uname -s 2>/dev/null || echo unknown)"

  echo "Host OS: $host_os"
  echo "Download directory: $DOWNLOAD_DIR"
  echo

  echo "=== Common tools ==="
  for cmd in "${required_common[@]}"; do
    if have "$cmd"; then
      echo "[OK] $cmd"
    else
      echo "[WARN] Missing: $cmd"
    fi
  done

  echo
  echo "=== USB creation tools ==="
  for cmd in "${required_usb[@]}"; do
    if have "$cmd"; then
      echo "[OK] $cmd"
    else
      echo "[WARN] Missing: $cmd"
    fi
  done

  echo
  echo "=== Windows USB support ==="
  if have wimlib-imagex; then
    echo "[OK] wimlib-imagex available for splitting install.wim onto FAT32"
  else
    echo "[WARN] wimlib-imagex missing. Install package: wimtools"
  fi

  echo
  echo "=== macOS installer support ==="
  if [[ "$host_os" == "Darwin" ]]; then
    echo "[OK] macOS host detected"
    if have softwareupdate; then
      echo "[OK] softwareupdate available"
    else
      echo "[WARN] softwareupdate missing"
    fi
    echo "[INFO] createinstallmedia is inside the downloaded Install macOS.app bundle"
  else
    echo "[WARN] Full official macOS USB creation requires macOS and createinstallmedia"
    echo "[INFO] On Linux, use this tool for OpenCore scaffolds, not official full macOS installer creation"
  fi

  echo
  echo "=== Recommended flow ==="
  echo "Ubuntu: download-ubuntu -> prepare-usb-ubuntu or build-tripleboot-usb"
  echo "Windows: download-windows --iso-url/--iso-file -> prepare-usb-windows or build-tripleboot-usb"
  echo "macOS: run download-macos/prepare-usb-macos from macOS only; Linux can stage OpenCore/OSX-KVM assets"
  echo "End-to-end kit: usb-plan -> build-tripleboot-usb -> tripleboot-usb-status"
}

download_ubuntu() {
  local version="26.04"
  local edition="desktop"
  local arch="amd64"
  local file=""
  local base_url=""
  local iso_url=""
  local sha_url=""
  local dest=""
  local sha_file=""
  local check_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      --edition) edition="$2"; shift 2 ;;
      --arch) arch="$2"; shift 2 ;;
      *) die "Unknown download-ubuntu arg: $1" ;;
    esac
  done

  case "$edition" in
    desktop) file="ubuntu-${version}-desktop-${arch}.iso" ;;
    server|live-server) file="ubuntu-${version}-live-server-${arch}.iso" ;;
    *) die "Unsupported Ubuntu edition: $edition. Use desktop or server." ;;
  esac

  base_url="https://releases.ubuntu.com/${version}"
  iso_url="${base_url}/${file}"
  sha_url="${base_url}/SHA256SUMS"
  dest="$DOWNLOAD_DIR/installers/ubuntu/$file"
  sha_file="$DOWNLOAD_DIR/installers/ubuntu/SHA256SUMS"
  check_file="$DOWNLOAD_DIR/installers/ubuntu/SHA256SUMS.${file}"

  mkdir -p "$DOWNLOAD_DIR/installers/ubuntu"

  echo "Ubuntu ISO: $iso_url"
  download_url "$iso_url" "$dest"
  download_url "$sha_url" "$sha_file"

  grep -E "[ *]${file}$" "$sha_file" > "$check_file" || die "Could not find $file inside SHA256SUMS"
  (
    cd "$DOWNLOAD_DIR/installers/ubuntu"
    sha256sum -c "$(basename "$check_file")"
  )

  echo "[OK] Ubuntu ISO downloaded and verified: $dest"
}

verify_iso_sha256() {
  local iso=""
  local sha256_file=""
  local iso_base=""
  local check_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iso) iso="$2"; shift 2 ;;
      --sha256-file) sha256_file="$2"; shift 2 ;;
      *) die "Unknown verify-iso-sha256 arg: $1" ;;
    esac
  done

  [[ -f "$iso" ]] || die "ISO not found: $iso"
  [[ -f "$sha256_file" ]] || die "SHA256 file not found: $sha256_file"

  iso_base="$(basename "$iso")"
  check_file="$(mktemp)"

  grep -E "[ *]${iso_base}$" "$sha256_file" > "$check_file" || die "Could not find $iso_base in $sha256_file"
  (
    cd "$(dirname "$iso")"
    sha256sum -c "$check_file"
  )
  rm -f "$check_file"

  echo "[OK] Verified: $iso"
}

download_windows() {
  local iso_url=""
  local iso_file=""
  local output_name="Windows11.iso"
  local dest=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iso-url) iso_url="$2"; shift 2 ;;
      --iso-file) iso_file="$2"; shift 2 ;;
      --output-name) output_name="$2"; shift 2 ;;
      *) die "Unknown download-windows arg: $1" ;;
    esac
  done

  mkdir -p "$DOWNLOAD_DIR/installers/windows"
  dest="$DOWNLOAD_DIR/installers/windows/$output_name"

  if [[ -n "$iso_file" ]]; then
    [[ -f "$iso_file" ]] || die "Windows ISO file not found: $iso_file"
    run cp -f "$iso_file" "$dest"
  elif [[ -n "$iso_url" ]]; then
    download_url "$iso_url" "$dest"
  else
    die "Windows ISO requires --iso-url URL or --iso-file FILE. Use Microsoft's official page to generate the ISO URL."
  fi

  echo "[OK] Windows ISO staged: $dest"
}

prepare_usb_dd() {
  need_root
  local usb=""
  local iso=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --usb-disk) usb="$2"; shift 2 ;;
      --iso) iso="$2"; shift 2 ;;
      --yes-destroy) YES_DESTROY=true; shift ;;
      *) die "Unknown prepare-usb-dd arg: $1" ;;
    esac
  done

  [[ -f "$iso" ]] || die "ISO not found: $iso"
  assert_disk "$usb"
  protect_running_root "$usb"
  [[ "$YES_DESTROY" == true ]] || die "USB write is destructive. Add --yes-destroy."

  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,LABEL,MOUNTPOINTS,MODEL
  confirm WRITE_ISO_TO_USB "This will overwrite the entire USB disk: $usb"

  unmount_disk "$usb"
  run dd if="$iso" of="$usb" bs=4M status=progress conv=fsync
  run sync

  echo "[OK] ISO written to USB: $usb"
}

prepare_usb_ubuntu() {
  local usb=""
  local iso=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --usb-disk) usb="$2"; shift 2 ;;
      --iso) iso="$2"; shift 2 ;;
      --yes-destroy) YES_DESTROY=true; shift ;;
      *) die "Unknown prepare-usb-ubuntu arg: $1" ;;
    esac
  done

  prepare_usb_dd --usb-disk "$usb" --iso "$iso" --yes-destroy
}

prepare_usb_windows() {
  need_root
  require sgdisk
  require wipefs
  require partprobe
  require mkfs.vfat
  require mount
  require umount
  require rsync
  require wimlib-imagex

  local usb=""
  local iso=""
  local part=""
  local iso_mnt=""
  local usb_mnt=""
  local wim_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --usb-disk) usb="$2"; shift 2 ;;
      --iso) iso="$2"; shift 2 ;;
      --yes-destroy) YES_DESTROY=true; shift ;;
      *) die "Unknown prepare-usb-windows arg: $1" ;;
    esac
  done

  [[ -f "$iso" ]] || die "Windows ISO not found: $iso"
  assert_disk "$usb"
  protect_running_root "$usb"
  [[ "$YES_DESTROY" == true ]] || die "USB formatting is destructive. Add --yes-destroy."

  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,LABEL,MOUNTPOINTS,MODEL
  confirm WIPE_WINDOWS_USB "This will erase USB disk $usb and create a Windows installer."

  unmount_disk "$usb"
  run sgdisk --zap-all "$usb"
  run wipefs -af "$usb"
  run sgdisk -n 1:1MiB:0 -t 1:0700 -c 1:WININSTALL "$usb"
  run partprobe "$usb"
  sleep 2

  part="$(part_name "$usb" 1)"
  run mkfs.vfat -F32 -n WININSTALL "$part"

  iso_mnt="$(mktemp -d)"
  usb_mnt="$(mktemp -d)"

  run mount -o loop,ro "$iso" "$iso_mnt"
  run mount "$part" "$usb_mnt"

  wim_file="$(find "$iso_mnt/sources" -maxdepth 1 -iname 'install.wim' -print -quit 2>/dev/null || true)"

  if [[ -n "$wim_file" ]]; then
    run rsync -rlt --info=progress2 --exclude='/sources/install.wim' "$iso_mnt"/ "$usb_mnt"/
    mkdir -p "$usb_mnt/sources"
    run wimlib-imagex split "$wim_file" "$usb_mnt/sources/install.swm" 3800
  else
    run rsync -rlt --info=progress2 "$iso_mnt"/ "$usb_mnt"/
  fi

  sync
  run umount "$usb_mnt"
  run umount "$iso_mnt"
  rmdir "$usb_mnt" "$iso_mnt" || true

  echo "[OK] Windows USB installer prepared: $usb"
}

download_macos() {
  local version=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      *) die "Unknown download-macos arg: $1" ;;
    esac
  done

  if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" ]]; then
    echo "[BLOCKED] Official macOS installer download requires macOS."
    echo "Use a real Mac, your macOS VM, or booted macOS system, then rerun this command there."
    return 2
  fi

  require softwareupdate

  if [[ -n "$version" ]]; then
    run softwareupdate --fetch-full-installer --full-installer-version "$version"
  else
    echo "Available installers:"
    softwareupdate --list-full-installers
    echo
    echo "Rerun with: download-macos --version VERSION"
  fi
}

prepare_usb_macos() {
  need_root

  local volume_name=""
  local app_path=""
  local tool=""
  local volume=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --volume-name) volume_name="$2"; shift 2 ;;
      --app-path) app_path="$2"; shift 2 ;;
      *) die "Unknown prepare-usb-macos arg: $1" ;;
    esac
  done

  if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" ]]; then
    echo "[BLOCKED] Official macOS bootable USB creation requires macOS createinstallmedia."
    return 2
  fi

  [[ -n "$volume_name" ]] || die "Missing --volume-name"
  volume="/Volumes/$volume_name"
  [[ -d "$volume" ]] || die "Volume not found: $volume"

  if [[ -z "$app_path" ]]; then
    app_path="$(find /Applications -maxdepth 1 -type d -name 'Install macOS*.app' | sort | tail -n1 || true)"
  fi

  [[ -d "$app_path" ]] || die "Install macOS.app not found. Use --app-path PATH."
  tool="$app_path/Contents/Resources/createinstallmedia"
  [[ -x "$tool" ]] || die "createinstallmedia not found at: $tool"

  confirm ERASE_MACOS_USB "This will erase the macOS USB volume: $volume"
  run "$tool" --volume "$volume" --nointeraction

  echo "[OK] macOS bootable installer prepared on: $volume"
}



download_ventoy() {
  local version="latest"
  local url=""
  local out=""
  local extract_dir="$DOWNLOAD_DIR/ventoy"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      *) die "Unknown download-ventoy arg: $1" ;;
    esac
  done

  mkdir -p "$extract_dir"

  if [[ "$version" == "latest" ]]; then
    url="$(github_latest_asset_url ventoy/Ventoy 'ventoy-.*-linux\.tar\.gz$')"
    out="$DOWNLOAD_DIR/ventoy/ventoy-latest-linux.tar.gz"
  else
    url="https://github.com/ventoy/Ventoy/releases/download/v${version}/ventoy-${version}-linux.tar.gz"
    out="$DOWNLOAD_DIR/ventoy/ventoy-${version}-linux.tar.gz"
  fi

  download_url "$url" "$out"

  rm -rf "$extract_dir/extracted"
  mkdir -p "$extract_dir/extracted"
  run tar -xzf "$out" -C "$extract_dir/extracted"

  echo "[OK] Ventoy downloaded and extracted:"
  find "$extract_dir/extracted" -maxdepth 2 -type f -name Ventoy2Disk.sh -print
}

ventoy_tool_path() {
  local tool=""
  tool="$(find "$DOWNLOAD_DIR/ventoy/extracted" -maxdepth 3 -type f -name Ventoy2Disk.sh -print -quit 2>/dev/null || true)"
  [[ -n "$tool" ]] || die "Ventoy2Disk.sh not found. Run: download-ventoy"
  printf '%s\n' "$tool"
}

prepare_usb_ventoy() {
  need_root

  local usb=""
  local secure_boot=false
  local gpt=true
  local tool=""
  local args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --usb-disk) usb="$2"; shift 2 ;;
      --secure-boot) secure_boot=true; shift ;;
      --mbr) gpt=false; shift ;;
      --yes-destroy) YES_DESTROY=true; shift ;;
      *) die "Unknown prepare-usb-ventoy arg: $1" ;;
    esac
  done

  [[ -n "$usb" ]] || die "Missing --usb-disk"
  assert_disk "$usb"
  protect_running_root "$usb"
  [[ "$YES_DESTROY" == true ]] || die "Ventoy install is destructive. Add --yes-destroy."

  tool="$(ventoy_tool_path)"

  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS,MODEL,TRAN
  confirm INSTALL_VENTOY "This will erase USB disk $usb and install Ventoy."

  unmount_disk "$usb"

  args=(-I)
  if [[ "$gpt" == true ]]; then
    args+=(-g)
  fi
  if [[ "$secure_boot" == true ]]; then
    args+=(-s)
  fi

  run bash "$tool" "${args[@]}" "$usb"
  run partprobe "$usb"
  sleep 3

  echo "[OK] Ventoy installed on: $usb"
}

ventoy_data_partition() {
  local usb="$1"
  local part=""

  part="$(lsblk -rpno NAME,LABEL "$usb" 2>/dev/null | awk '$2 == "Ventoy" {print $1; exit}' || true)"
  if [[ -z "$part" ]]; then
    part="$(part_name "$usb" 1)"
  fi

  [[ -b "$part" ]] || die "Could not detect Ventoy data partition for $usb"
  printf '%s\n' "$part"
}

mount_ventoy_data_rw() {
  local usb="$1"
  local part=""
  local mnt=""

  part="$(ventoy_data_partition "$usb")"
  mnt="$(mktemp -d)"

  run mount "$part" "$mnt"
  printf '%s\n' "$mnt"
}

usb_plan() {
  local include_osx_kvm=false
  local include_opencore=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include-osx-kvm) include_osx_kvm=true; shift ;;
      --include-opencore) include_opencore=true; shift ;;
      *) die "Unknown usb-plan arg: $1" ;;
    esac
  done

  tripleboot_banner
  cat <<EOF_USB_PLAN
TripleBoot USB end-to-end plan

Purpose:
  Build one UEFI-bootable USB kit that carries Ubuntu, Windows, project runbooks,
  checksums, optional OpenCore EFI files, and optional OSX-KVM recovery assets.

Recommended command:
  sudo scripts/tripleboot_aio.sh build-tripleboot-usb --usb-disk /dev/sdX --windows-iso /path/to/Windows.iso --ubuntu-version 26.04 --include-opencore --yes-destroy

Pipeline:
  1. installer-doctor validates required host tools.
  2. download-ubuntu downloads and verifies the Ubuntu ISO with SHA256SUMS.
  3. download-windows stages a user-provided official Microsoft ISO or URL.
  4. download-ventoy fetches the multiboot USB engine.
  5. prepare-usb-ventoy erases the selected USB and installs Ventoy.
  6. stage-tripleboot-usb copies installers, docs, generated guides, manifest,
     SHA256SUMS, and optional macOS lab/recovery assets.
  7. tripleboot-usb-status mounts the USB read-only enough to report payloads.

Payload layout:
  /ISO/Ubuntu/              Ubuntu installer ISO(s)
  /ISO/Windows/             Windows installer ISO(s)
  /EFI/OPENCORE/            Optional OpenCore EFI payload for manual copying
  /macOS/OSX-KVM/           Optional Linux-hosted macOS VM/recovery workflow
  /TripleBoot/README-FIRST.txt
  /TripleBoot/QUICKSTART.md
  /TripleBoot/MANIFEST.json
  /TripleBoot/SHA256SUMS
  /TripleBoot/repo/         Offline copy of this repository's docs/scripts
  /ventoy/ventoy.json       Human-friendly Ventoy menu aliases

Safety model:
  - The USB build is destructive and requires --yes-destroy plus typed confirmation.
  - The tool refuses to target the running root disk unless --force is supplied.
  - macOS installer binaries are not distributed or generated on Linux.
  - OpenCore files are staged as a reviewable lab payload, not auto-installed to an internal ESP.

Current options:
  Include OSX-KVM assets: $include_osx_kvm
  Include OpenCore EFI:  $include_opencore
EOF_USB_PLAN
}

write_ventoy_config() {
  local mnt="$1"
  mkdir -p "$mnt/ventoy"
  cat > "$mnt/ventoy/ventoy.json" <<'EOF_VENTOY'
{
  "control": [
    { "VTOY_DEFAULT_MENU_MODE": "0" },
    { "VTOY_TREE_VIEW_MENU_STYLE": "1" }
  ],
  "menu_alias": [
    { "image": "/ISO/Ubuntu/", "alias": "Ubuntu installer" },
    { "image": "/ISO/Windows/", "alias": "Windows installer" },
    { "image": "/macOS/OSX-KVM/", "alias": "macOS VM/OpenCore recovery assets (not directly bootable as an Apple installer)" }
  ]
}
EOF_VENTOY
}

write_tripleboot_usb_guides() {
  local mnt="$1"
  local include_osx_kvm="$2"
  local include_opencore="$3"
  local generated_at=""

  generated_at="$(date --iso-8601=seconds)"
  mkdir -p "$mnt/TripleBoot"

  cat > "$mnt/TripleBoot/README-FIRST.txt" <<EOF_README
TripleBoot USB

Generated: $generated_at
Tool: TripleBoot AIO v$VERSION

This USB is built as a Ventoy multiboot installer and recovery kit.

Boot menu:
- Ubuntu ISO(s): /ISO/Ubuntu
- Windows ISO(s): /ISO/Windows

macOS/OpenCore scope:
- Official full macOS USB creation requires macOS + createinstallmedia.
- Linux-hosted macOS assets, when included, live under /macOS/OSX-KVM.
- OpenCore EFI files, when included, live under /EFI/OPENCORE for manual review/copying.

Safety:
- Do not wipe internal disks until preflight-partition passes.
- Keep BitLocker recovery keys available before changing Windows boot files.
- Keep EFI backups before changing bootloaders.
- Treat OpenCore as hardware-specific; validate and review before booting bare metal.
EOF_README

  cat > "$mnt/TripleBoot/QUICKSTART.md" <<EOF_QUICKSTART
# TripleBoot USB quickstart

## 1. Boot policy

Boot this USB in **UEFI mode**. If firmware shows duplicate entries for the USB,
choose the one prefixed with `UEFI:`.

## 2. Install order

1. Boot Ubuntu installer from `/ISO/Ubuntu` and install to the Ubuntu disk.
2. Boot Windows installer from `/ISO/Windows` and install to the Windows partition/disk.
3. Only after Ubuntu and Windows are stable, test OpenCore from removable media.
4. Keep OpenCore experimental until `ocvalidate` and hardware-specific review pass.

## 3. On-USB payloads

- `TripleBoot/MANIFEST.json` records what this tool staged.
- `TripleBoot/SHA256SUMS` lets you verify staged payloads with `sha256sum -c`.
- `TripleBoot/repo/docs` contains the offline runbooks.
- Optional OSX-KVM included: `$include_osx_kvm`.
- Optional OpenCore EFI included: `$include_opencore`.

## 4. Before touching internal disks

From a Linux live session, run:

```bash
sudo TripleBoot/repo/scripts/tripleboot_aio.sh scan
sudo TripleBoot/repo/scripts/tripleboot_aio.sh installer-doctor
sudo TripleBoot/repo/scripts/tripleboot_aio.sh preflight-partition --ubuntu-disk /dev/nvme0n1 --winmac-disk /dev/nvme1n1
```

Adjust disk names to match `lsblk` output.
EOF_QUICKSTART
}

write_usb_manifest() {
  local mnt="$1"
  local usb="$2"
  local ubuntu_iso="$3"
  local windows_iso="$4"
  local include_osx_kvm="$5"
  local osx_kvm_dir="$6"
  local include_opencore="$7"
  local opencore_efi="$8"
  local include_repo_docs="$9"
  local manifest="$mnt/TripleBoot/MANIFEST.json"
  local sums="$mnt/TripleBoot/SHA256SUMS"
  local generated_at=""
  local ubuntu_name=""
  local windows_name=""

  require python3

  generated_at="$(date --iso-8601=seconds)"
  [[ -n "$ubuntu_iso" ]] && ubuntu_name="$(basename "$ubuntu_iso")"
  [[ -n "$windows_iso" ]] && windows_name="$(basename "$windows_iso")"

  python3 - "$manifest" "$VERSION" "$generated_at" "$usb" "$ubuntu_name" "$windows_name" "$include_osx_kvm" "$osx_kvm_dir" "$include_opencore" "$opencore_efi" "$include_repo_docs" <<'PY_MANIFEST'
import json
import sys

(
    manifest_path,
    version,
    generated_at,
    usb_disk,
    ubuntu_iso,
    windows_iso,
    include_osx_kvm,
    osx_kvm_dir,
    include_opencore,
    opencore_efi,
    include_repo_docs,
) = sys.argv[1:]

osx_kvm_included = include_osx_kvm == "true"
opencore_included = include_opencore == "true"
repo_docs_included = include_repo_docs == "true"

manifest = {
    "schema": "https://tripleboot.local/schemas/usb-manifest-v1.json",
    "tool": "TripleBoot AIO",
    "version": version,
    "generated_at": generated_at,
    "usb_disk": usb_disk,
    "payloads": {
        "ubuntu_iso": ubuntu_iso,
        "windows_iso": windows_iso,
        "osx_kvm_included": osx_kvm_included,
        "osx_kvm_source": osx_kvm_dir if osx_kvm_included else None,
        "opencore_included": opencore_included,
        "opencore_source": opencore_efi if opencore_included else None,
        "repo_docs_included": repo_docs_included,
    },
    "warnings": [
        "Destructive disk operations still require a separate preflight and explicit confirmation.",
        "OpenCore configuration is hardware-specific and must be manually reviewed.",
        "Official macOS bootable installers require macOS createinstallmedia.",
    ],
}

with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY_MANIFEST

  (
    cd "$mnt"
    find ISO EFI macOS TripleBoot -type f 2>/dev/null \
      ! -path 'TripleBoot/SHA256SUMS' \
      ! -path 'TripleBoot/repo/.git/*' \
      -print0 | sort -z | xargs -0 sha256sum
  ) > "$sums"
}

stage_tripleboot_usb() {
  need_root

  local usb=""
  local ubuntu_iso=""
  local windows_iso=""
  local osx_kvm_dir=""
  local include_osx_kvm=false
  local include_opencore=false
  local include_repo_docs=true
  local opencore_efi=""
  local mnt=""
  local repo_root=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --usb-disk) usb="$2"; shift 2 ;;
      --ubuntu-iso) ubuntu_iso="$2"; shift 2 ;;
      --windows-iso) windows_iso="$2"; shift 2 ;;
      --osx-kvm-dir) osx_kvm_dir="$2"; include_osx_kvm=true; shift 2 ;;
      --include-osx-kvm) include_osx_kvm=true; shift ;;
      --opencore-efi) opencore_efi="$2"; include_opencore=true; shift 2 ;;
      --include-opencore) include_opencore=true; shift ;;
      --no-repo-docs) include_repo_docs=false; shift ;;
      *) die "Unknown stage-tripleboot-usb arg: $1" ;;
    esac
  done

  [[ -n "$usb" ]] || die "Missing --usb-disk"
  assert_disk "$usb"
  protect_running_root "$usb"

  [[ -z "$ubuntu_iso" || -f "$ubuntu_iso" ]] || die "Ubuntu ISO not found: $ubuntu_iso"
  [[ -z "$windows_iso" || -f "$windows_iso" ]] || die "Windows ISO not found: $windows_iso"

  if [[ "$include_osx_kvm" == true ]]; then
    [[ -n "$osx_kvm_dir" ]] || osx_kvm_dir="$(osx_kvm_dir_default)"
    [[ -d "$osx_kvm_dir" ]] || die "OSX-KVM dir not found: $osx_kvm_dir"
  fi

  if [[ "$include_opencore" == true ]]; then
    [[ -n "$opencore_efi" ]] || opencore_efi="$BUILD_DIR/EFI"
    [[ -d "$opencore_efi/OC" && -d "$opencore_efi/BOOT" ]] || die "OpenCore EFI payload not found at $opencore_efi. Run download-opencore, download-kexts, and build-opencore-scaffold first, or pass --opencore-efi DIR."
  fi

  mnt="$(mount_ventoy_data_rw "$usb")"

  mkdir -p "$mnt/ISO/Ubuntu" "$mnt/ISO/Windows" "$mnt/macOS/OSX-KVM" "$mnt/TripleBoot" "$mnt/EFI"

  if [[ -n "$ubuntu_iso" ]]; then
    run rsync -ah --info=progress2 "$ubuntu_iso" "$mnt/ISO/Ubuntu/"
  fi

  if [[ -n "$windows_iso" ]]; then
    run rsync -ah --info=progress2 "$windows_iso" "$mnt/ISO/Windows/"
  fi

  if [[ "$include_osx_kvm" == true ]]; then
    echo "[INFO] Staging OSX-KVM assets. This is VM/recovery workflow data, not official Apple createinstallmedia USB."
    run rsync -ah --info=progress2 \
      --exclude='.git' \
      --exclude='mac_hdd_ng.img' \
      --exclude='*.qcow2' \
      "$osx_kvm_dir"/ "$mnt/macOS/OSX-KVM/"
  fi

  if [[ "$include_opencore" == true ]]; then
    mkdir -p "$mnt/EFI/OPENCORE"
    run rsync -aHAX --delete "$opencore_efi"/ "$mnt/EFI/OPENCORE/"
  fi

  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  if [[ "$include_repo_docs" == true && -d "$repo_root" ]]; then
    run rsync -ah \
      --exclude='.git' \
      --exclude='downloads' \
      --exclude='build' \
      --exclude='inventory' \
      --exclude='backups' \
      "$repo_root"/ "$mnt/TripleBoot/repo/"
  fi

  write_ventoy_config "$mnt"
  write_tripleboot_usb_guides "$mnt" "$include_osx_kvm" "$include_opencore"
  write_usb_manifest "$mnt" "$usb" "$ubuntu_iso" "$windows_iso" "$include_osx_kvm" "$osx_kvm_dir" "$include_opencore" "$opencore_efi" "$include_repo_docs"

  sync
  run umount "$mnt"
  rmdir "$mnt" || true

  echo "[OK] TripleBoot USB payload staged on: $usb"
}

tripleboot_usb_status() {
  need_root

  local usb=""
  local part=""
  local mnt=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --usb-disk) usb="$2"; shift 2 ;;
      *) die "Unknown tripleboot-usb-status arg: $1" ;;
    esac
  done

  [[ -n "$usb" ]] || die "Missing --usb-disk"
  assert_disk "$usb"

  echo "=== USB disk ==="
  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS,MODEL,TRAN "$usb"

  part="$(ventoy_data_partition "$usb")"
  echo
  echo "Ventoy data partition: $part"

  mnt="$(mktemp -d)"
  run mount "$part" "$mnt"

  echo
  echo "=== Payload files ==="
  find "$mnt" -maxdepth 5 -type f \
    \( -iname '*.iso' -o -iname '*.img' -o -iname '*.dmg' -o -iname 'README-FIRST.txt' -o -iname 'QUICKSTART.md' -o -iname 'MANIFEST.json' -o -iname 'SHA256SUMS' -o -iname 'ventoy.json' \) \
    -printf '%P\n' | sort

  if [[ -f "$mnt/TripleBoot/MANIFEST.json" ]] && have jq; then
    echo
    echo "=== Manifest summary ==="
    jq -r '.payloads | to_entries[] | "\(.key): \(.value)"' "$mnt/TripleBoot/MANIFEST.json"
  fi

  echo
  echo "=== Expected directories ==="
  for d in ISO/Ubuntu ISO/Windows macOS/OSX-KVM TripleBoot EFI/OPENCORE ventoy; do
    if [[ -d "$mnt/$d" ]]; then
      echo "[OK] $d"
    else
      echo "[WARN] Missing $d"
    fi
  done

  run umount "$mnt"
  rmdir "$mnt" || true
}

build_tripleboot_usb() {
  need_root

  local usb=""
  local ubuntu_version="26.04"
  local ubuntu_edition="desktop"
  local ubuntu_arch="amd64"
  local ubuntu_iso=""
  local windows_iso=""
  local windows_iso_url=""
  local staged_windows_iso=""
  local include_osx_kvm=false
  local include_opencore=false
  local osx_kvm_dir=""
  local opencore_efi=""
  local opencore_smbios="iMac20,1"
  local opencore_gpu_policy="disable-nvidia"
  local skip_downloads=false
  local secure_boot=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --usb-disk) usb="$2"; shift 2 ;;
      --ubuntu-version) ubuntu_version="$2"; shift 2 ;;
      --ubuntu-edition) ubuntu_edition="$2"; shift 2 ;;
      --ubuntu-arch) ubuntu_arch="$2"; shift 2 ;;
      --ubuntu-iso) ubuntu_iso="$2"; shift 2 ;;
      --windows-iso) windows_iso="$2"; shift 2 ;;
      --windows-iso-url) windows_iso_url="$2"; shift 2 ;;
      --include-osx-kvm) include_osx_kvm=true; shift ;;
      --osx-kvm-dir) osx_kvm_dir="$2"; include_osx_kvm=true; shift 2 ;;
      --include-opencore) include_opencore=true; shift ;;
      --opencore-efi) opencore_efi="$2"; include_opencore=true; shift 2 ;;
      --opencore-smbios) opencore_smbios="$2"; shift 2 ;;
      --opencore-gpu-policy) opencore_gpu_policy="$2"; shift 2 ;;
      --skip-downloads) skip_downloads=true; shift ;;
      --secure-boot) secure_boot=true; shift ;;
      --yes-destroy) YES_DESTROY=true; shift ;;
      *) die "Unknown build-tripleboot-usb arg: $1" ;;
    esac
  done

  [[ -n "$usb" ]] || die "Missing --usb-disk"
  assert_disk "$usb"
  protect_running_root "$usb"
  [[ "$YES_DESTROY" == true ]] || die "USB build is destructive. Add --yes-destroy."

  if [[ -z "$windows_iso" && -z "$windows_iso_url" ]]; then
    die "Windows installer requires --windows-iso FILE or --windows-iso-url URL."
  fi

  echo "=== TripleBoot USB build plan ==="
  echo "USB disk: $usb"
  echo "Ubuntu: ${ubuntu_version} ${ubuntu_edition} ${ubuntu_arch}"
  echo "Windows ISO file: ${windows_iso:-not provided}"
  echo "Windows ISO URL: ${windows_iso_url:+provided}"
  echo "Include OSX-KVM assets: $include_osx_kvm"
  echo "Include OpenCore EFI: $include_opencore"
  echo "OpenCore SMBIOS/GPU policy: $opencore_smbios / $opencore_gpu_policy"
  echo "Secure Boot support in Ventoy: $secure_boot"
  echo
  echo "[DANGER] This will erase the selected USB disk, install Ventoy, and stage installers."
  confirm BUILD_TRIPLEBOOT_USB "Confirm full TripleBoot USB build on $usb."

  if [[ "$skip_downloads" != true ]]; then
    if [[ -z "$ubuntu_iso" ]]; then
      download_ubuntu --version "$ubuntu_version" --edition "$ubuntu_edition" --arch "$ubuntu_arch"
      case "$ubuntu_edition" in
        desktop) ubuntu_iso="$DOWNLOAD_DIR/installers/ubuntu/ubuntu-${ubuntu_version}-desktop-${ubuntu_arch}.iso" ;;
        server|live-server) ubuntu_iso="$DOWNLOAD_DIR/installers/ubuntu/ubuntu-${ubuntu_version}-live-server-${ubuntu_arch}.iso" ;;
      esac
    fi

    if [[ -n "$windows_iso_url" ]]; then
      download_windows --iso-url "$windows_iso_url" --output-name Windows11.iso
      staged_windows_iso="$DOWNLOAD_DIR/installers/windows/Windows11.iso"
    elif [[ -n "$windows_iso" ]]; then
      download_windows --iso-file "$windows_iso" --output-name "$(basename "$windows_iso")"
      staged_windows_iso="$DOWNLOAD_DIR/installers/windows/$(basename "$windows_iso")"
    fi

    if [[ "$include_osx_kvm" == true ]]; then
      [[ -n "$osx_kvm_dir" ]] || osx_kvm_dir="$(osx_kvm_dir_default)"
      osx_kvm_clone --dir "$osx_kvm_dir"
      if [[ ! -f "$osx_kvm_dir/BaseSystem.img" ]]; then
        echo "[INFO] OSX-KVM BaseSystem.img not found."
        echo "[INFO] Run osx-kvm-fetch and osx-kvm-convert manually if you want macOS recovery assets staged."
      fi
    fi

    if [[ "$include_opencore" == true && -z "$opencore_efi" ]]; then
      download_opencore
      download_kexts
      build_opencore_scaffold --smbios "$opencore_smbios" --gpu-policy "$opencore_gpu_policy"
      opencore_efi="$BUILD_DIR/EFI"
    fi
  else
    staged_windows_iso="$windows_iso"
  fi

  if [[ "$include_opencore" == true ]]; then
    [[ -n "$opencore_efi" ]] || opencore_efi="$BUILD_DIR/EFI"
    [[ -d "$opencore_efi/OC" && -d "$opencore_efi/BOOT" ]] || die "OpenCore EFI payload missing: $opencore_efi"
  fi

  [[ -n "$ubuntu_iso" && -f "$ubuntu_iso" ]] || die "Ubuntu ISO missing after download/stage: $ubuntu_iso"
  [[ -n "$staged_windows_iso" && -f "$staged_windows_iso" ]] || die "Windows ISO missing after download/stage: $staged_windows_iso"

  download_ventoy

  if [[ "$secure_boot" == true ]]; then
    prepare_usb_ventoy --usb-disk "$usb" --secure-boot --yes-destroy
  else
    prepare_usb_ventoy --usb-disk "$usb" --yes-destroy
  fi

  local -a stage_args=(--usb-disk "$usb" --ubuntu-iso "$ubuntu_iso" --windows-iso "$staged_windows_iso")
  if [[ "$include_osx_kvm" == true ]]; then
    stage_args+=(--osx-kvm-dir "${osx_kvm_dir:-$(osx_kvm_dir_default)}")
  fi
  if [[ "$include_opencore" == true ]]; then
    stage_args+=(--opencore-efi "$opencore_efi")
  fi
  stage_tripleboot_usb "${stage_args[@]}"

  tripleboot_usb_status --usb-disk "$usb"

  echo
  echo "[OK] TripleBoot USB installer kit complete."
  echo "[INFO] Boot the USB and Ventoy should list Ubuntu and Windows ISOs."
  echo "[INFO] macOS assets, if included, are under /macOS/OSX-KVM for VM/OpenCore recovery workflow."
}

osx_kvm_dir_default() {
  local owner="${SUDO_USER:-${USER:-}}"
  local owner_home=""

  if [[ -n "${OSX_KVM_DIR:-}" ]]; then
    printf '%s\n' "$OSX_KVM_DIR"
    return 0
  fi

  if [[ -n "$owner" && "$owner" != "root" ]]; then
    owner_home="$(getent passwd "$owner" | cut -d: -f6 || true)"
  fi

  if [[ -n "$owner_home" ]]; then
    printf '%s\n' "$owner_home/OSX-KVM"
  else
    printf '%s\n' "$HOME/OSX-KVM"
  fi
}

osx_kvm_doctor() {
  ui_section "OSX-KVM doctor"

  local repo_dir=""
  local cpu_flags=""
  local missing=0
  local cmd=""

  repo_dir="$(osx_kvm_dir_default)"
  cpu_flags="$(grep -m1 -E '^flags|^Features' /proc/cpuinfo 2>/dev/null || true)"

  echo "OSX-KVM directory: $repo_dir"
  echo

  echo "=== Required virtualization ==="
  if grep -Eq 'vmx|svm' /proc/cpuinfo 2>/dev/null; then
    echo "[OK] CPU virtualization flag found: vmx/svm"
  else
    echo "[WARN] CPU virtualization flag not found. Enable Intel VT-x / AMD SVM in BIOS."
  fi

  if [[ "$cpu_flags" == *sse4_1* || "$cpu_flags" == *sse4.1* ]]; then
    echo "[OK] SSE4.1 available"
  else
    echo "[WARN] SSE4.1 not detected"
  fi

  if [[ "$cpu_flags" == *avx2* ]]; then
    echo "[OK] AVX2 available for Ventura+"
  else
    echo "[WARN] AVX2 not detected. Ventura+ may not work."
  fi

  echo
  echo "=== Kernel KVM status ==="
  if [[ -e /dev/kvm ]]; then
    echo "[OK] /dev/kvm exists"
  else
    echo "[WARN] /dev/kvm missing. Try: sudo modprobe kvm_intel"
  fi

  if [[ -r /sys/module/kvm/parameters/ignore_msrs ]]; then
    echo "kvm.ignore_msrs: $(cat /sys/module/kvm/parameters/ignore_msrs)"
  else
    echo "[WARN] Could not read kvm ignore_msrs"
  fi

  echo
  echo "=== Tooling ==="
  for cmd in qemu-system-x86_64 qemu-img git wget dmg2img mkisofs make screen; do
    if have "$cmd"; then
      echo "[OK] $cmd"
    else
      echo "[WARN] Missing: $cmd"
      missing=$((missing + 1))
    fi
  done

  echo
  echo "=== Repository ==="
  if [[ -d "$repo_dir/.git" ]]; then
    echo "[OK] OSX-KVM repo exists: $repo_dir"
  else
    echo "[WARN] OSX-KVM repo not found. Run: sudo scripts/tripleboot_aio.sh osx-kvm-clone"
  fi

  echo
  echo "=== GPU expectation ==="
  echo "[WARN] OSX-KVM is VM/lab macOS. Do not expect native GPU acceleration by default."
}

osx_kvm_clone() {
  local repo_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) repo_dir="$2"; shift 2 ;;
      *) die "Unknown osx-kvm-clone arg: $1" ;;
    esac
  done

  [[ -n "$repo_dir" ]] || repo_dir="$(osx_kvm_dir_default)"

  if [[ -d "$repo_dir/.git" ]]; then
    echo "[OK] OSX-KVM already cloned: $repo_dir"
    return 0
  fi

  mkdir -p "$(dirname "$repo_dir")"
  run git clone --depth 1 --recursive https://github.com/kholia/OSX-KVM.git "$repo_dir"
  echo "[OK] OSX-KVM cloned: $repo_dir"
}

osx_kvm_fetch() {
  local repo_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) repo_dir="$2"; shift 2 ;;
      *) die "Unknown osx-kvm-fetch arg: $1" ;;
    esac
  done

  [[ -n "$repo_dir" ]] || repo_dir="$(osx_kvm_dir_default)"
  [[ -d "$repo_dir" ]] || die "OSX-KVM repo not found: $repo_dir"

  echo "[INFO] This opens the OSX-KVM macOS product selector."
  (
    cd "$repo_dir"
    run ./fetch-macOS-v2.py
  )
}

osx_kvm_convert() {
  local repo_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) repo_dir="$2"; shift 2 ;;
      *) die "Unknown osx-kvm-convert arg: $1" ;;
    esac
  done

  [[ -n "$repo_dir" ]] || repo_dir="$(osx_kvm_dir_default)"
  [[ -f "$repo_dir/BaseSystem.dmg" ]] || die "BaseSystem.dmg not found in $repo_dir. Run osx-kvm-fetch first."
  require dmg2img

  (
    cd "$repo_dir"
    run dmg2img -i BaseSystem.dmg BaseSystem.img
  )

  echo "[OK] Created: $repo_dir/BaseSystem.img"
}

osx_kvm_create_disk() {
  local repo_dir=""
  local size="256G"
  local disk_name="mac_hdd_ng.img"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) repo_dir="$2"; shift 2 ;;
      --size) size="$2"; shift 2 ;;
      --disk-name) disk_name="$2"; shift 2 ;;
      *) die "Unknown osx-kvm-create-disk arg: $1" ;;
    esac
  done

  [[ -n "$repo_dir" ]] || repo_dir="$(osx_kvm_dir_default)"
  [[ -d "$repo_dir" ]] || die "OSX-KVM repo not found: $repo_dir"
  require qemu-img

  if [[ -f "$repo_dir/$disk_name" ]]; then
    echo "[OK] Disk already exists: $repo_dir/$disk_name"
    return 0
  fi

  (
    cd "$repo_dir"
    run qemu-img create -f qcow2 "$disk_name" "$size"
  )

  echo "[OK] Created macOS VM disk: $repo_dir/$disk_name"
}

osx_kvm_boot() {
  local repo_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) repo_dir="$2"; shift 2 ;;
      *) die "Unknown osx-kvm-boot arg: $1" ;;
    esac
  done

  [[ -n "$repo_dir" ]] || repo_dir="$(osx_kvm_dir_default)"
  [[ -x "$repo_dir/OpenCore-Boot.sh" ]] || die "OpenCore-Boot.sh not found or not executable in $repo_dir"
  [[ -f "$repo_dir/BaseSystem.img" ]] || echo "[WARN] BaseSystem.img not found. Install boot may fail unless already installed."
  [[ -f "$repo_dir/mac_hdd_ng.img" ]] || echo "[WARN] mac_hdd_ng.img not found. Run osx-kvm-create-disk first."

  (
    cd "$repo_dir"
    run ./OpenCore-Boot.sh
  )
}

osx_kvm_offline_iso() {
  local repo_dir=""
  local pkg=""
  local output="InstallAssistant.iso"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) repo_dir="$2"; shift 2 ;;
      --pkg) pkg="$2"; shift 2 ;;
      --output) output="$2"; shift 2 ;;
      *) die "Unknown osx-kvm-offline-iso arg: $1" ;;
    esac
  done

  [[ -n "$repo_dir" ]] || repo_dir="$(osx_kvm_dir_default)"
  [[ -f "$pkg" ]] || die "InstallAssistant.pkg not found: $pkg"
  [[ -f "$repo_dir/scripts/run_offline.sh" ]] || die "run_offline.sh not found in $repo_dir/scripts"
  require mkisofs

  (
    cd "$repo_dir"
    run mkisofs -allow-limited-size -l -J -r -iso-level 3 -V InstallAssistant -o "$output" "$pkg" scripts/run_offline.sh
  )

  echo "[OK] Offline InstallAssistant ISO created: $repo_dir/$output"
  echo "[INFO] You still need to attach it to OpenCore-Boot.sh as MacDVD, matching OSX-KVM offline docs."
}

preflight_partition() {
  ui_section "Preflight partition safety check"

  need_root

  local ubuntu_disk=""
  local winmac_disk=""
  local rootdisk=""
  local failures=0
  local warnings=0
  local disk=""
  local part=""
  local mounted_parts=""
  local latest_backup=""
  local efi_count="0"
  local -a allow_data_wipe_disks=()
  local allowed_disk=""
  local data_wipe_allowed=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ubuntu-disk) ubuntu_disk="$2"; shift 2 ;;
      --winmac-disk) winmac_disk="$2"; shift 2 ;;
      --allow-wipe-data-on) allow_data_wipe_disks+=("$2"); shift 2 ;;
      *) die "Unknown preflight-partition arg: $1" ;;
    esac
  done

  [[ -n "$ubuntu_disk" ]] || die "Missing --ubuntu-disk"
  [[ -n "$winmac_disk" ]] || die "Missing --winmac-disk"

  echo "Ubuntu target disk: $ubuntu_disk"
  echo "Windows/macOS target disk: $winmac_disk"
  if [[ "${#allow_data_wipe_disks[@]}" -gt 0 ]]; then
    echo "Explicit DATA wipe override(s): ${allow_data_wipe_disks[*]}"
  fi
  echo

  echo "=== UEFI / Secure Boot ==="
  if is_uefi; then
    echo "[OK] Booted in UEFI mode"
  else
    echo "[BLOCKED] Not booted in UEFI mode"
    failures=$((failures + 1))
  fi

  if have mokutil; then
    if mokutil --sb-state 2>/dev/null | grep -qi 'disabled'; then
      echo "[OK] Secure Boot disabled"
    else
      echo "[WARN] Secure Boot may be enabled or unknown"
      warnings=$((warnings + 1))
    fi
  else
    echo "[WARN] mokutil unavailable"
    warnings=$((warnings + 1))
  fi

  echo
  echo "=== Disk identity ==="
  for disk in "$ubuntu_disk" "$winmac_disk"; do
    if [[ -b "$disk" ]] && [[ "$(lsblk -dn -o TYPE "$disk" 2>/dev/null || true)" == "disk" ]]; then
      echo "[OK] Whole disk exists: $disk"
    else
      echo "[BLOCKED] Not a valid whole disk: $disk"
      failures=$((failures + 1))
    fi
  done

  if [[ "$ubuntu_disk" == "$winmac_disk" ]]; then
    echo "[BLOCKED] Ubuntu disk and Windows/macOS disk are identical"
    failures=$((failures + 1))
  fi

  echo
  echo "=== Running root protection ==="
  rootdisk="$(root_parent_disk || true)"
  echo "Running root disk: ${rootdisk:-unknown}"
  for disk in "$ubuntu_disk" "$winmac_disk"; do
    if [[ -n "$rootdisk" && "$disk" == "$rootdisk" ]]; then
      echo "[BLOCKED] $disk is the currently running root disk"
      failures=$((failures + 1))
    fi
  done

  echo
  echo "=== DATA partition protection ==="
  mapfile -t data_partitions < <(lsblk -rpno NAME,PARTLABEL,LABEL | awk '$2 == "DATA" || $3 == "DATA" {print $1}' || true)
  if [[ "${#data_partitions[@]}" -gt 0 ]]; then
    local data_partition data_parent
    for data_partition in "${data_partitions[@]}"; do
      [[ -n "$data_partition" ]] || continue
      data_parent="$(lsblk -no PKNAME "$data_partition" 2>/dev/null | head -n1 || true)"
      if [[ -n "$data_parent" && "$data_parent" != /dev/* ]]; then
        data_parent="/dev/$data_parent"
      fi
      echo "[WARN] DATA partition detected: $data_partition"
      echo "       Parent disk: ${data_parent:-unknown}"
      if [[ "$data_parent" == "$ubuntu_disk" || "$data_parent" == "$winmac_disk" ]]; then
        data_wipe_allowed=false
        for allowed_disk in "${allow_data_wipe_disks[@]}"; do
          if [[ "$allowed_disk" == "$data_parent" ]]; then
            data_wipe_allowed=true
            break
          fi
        done

        if [[ "$data_wipe_allowed" == true ]]; then
          echo "[DANGER-ACK] DATA wipe override accepted for: $data_parent"
        else
          echo "[BLOCKED] Target disk contains DATA: $data_parent"
          echo "          To allow this intentionally, rerun with: --allow-wipe-data-on $data_parent"
          failures=$((failures + 1))
        fi
      fi
    done
  else
    echo "[OK] No DATA partition detected"
  fi

  echo
  echo "=== Mounted partition check ==="
  for disk in "$ubuntu_disk" "$winmac_disk"; do
    mounted_parts="$(lsblk -rpno NAME,MOUNTPOINTS "$disk" 2>/dev/null | awk 'NF > 1 {print $0}' || true)"
    if [[ -n "$mounted_parts" ]]; then
      echo "[WARN] Mounted partitions found under $disk:"
      echo "$mounted_parts"
      warnings=$((warnings + 1))
    else
      echo "[OK] No mounted partitions under $disk"
    fi
  done

  echo
  echo "=== EFI backup check ==="
  latest_backup="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1 || true)"
  if [[ -n "$latest_backup" ]]; then
    efi_count="$(find "$latest_backup" -type f -iname '*.efi' 2>/dev/null | wc -l | tr -d ' ')"
    echo "Latest backup: $latest_backup"
    echo "EFI file count: $efi_count"
    if [[ "$efi_count" -gt 0 ]]; then
      echo "[OK] EFI backup exists and contains loaders"
    else
      echo "[BLOCKED] Latest EFI backup contains no EFI files"
      failures=$((failures + 1))
    fi
  else
    echo "[BLOCKED] No EFI backup found"
    failures=$((failures + 1))
  fi

  echo
  echo "=== Windows / BitLocker reminder ==="
  echo "[WARN] If Windows/BitLocker exists or will be installed, keep the recovery key and suspend BitLocker before bootloader edits."
  warnings=$((warnings + 1))

  echo
  echo "=== Preflight result ==="
  echo "Failures: $failures"
  echo "Warnings: $warnings"

  if [[ "$failures" -gt 0 ]]; then
    echo "[BLOCKED] Partitioning should not proceed."
    return 2
  fi

  echo "[OK] No hard blockers detected. Still use a live USB before destructive partitioning."
}

doctor() {
  ui_section "TripleBoot doctor"

  need_root

  local inv="$INVENTORY_DIR/parsed/inventory.json"
  local latest_backup=""
  local efi_count="0"
  local boot_order=""
  local rootdisk=""

  echo "=== System mode ==="
  if is_uefi; then
    echo "[OK] Booted in UEFI mode"
  else
    echo "[FAIL] Not booted in UEFI mode"
  fi

  if have mokutil; then
    mokutil --sb-state || true
  else
    echo "[WARN] mokutil not installed"
  fi

  echo
  echo "=== Hardware risk summary ==="
  if [[ -f "$inv" ]] && have jq; then
    echo "CPU: $(jq -r '.cpu_model // "unknown"' "$inv")"
    echo "Board: $(jq -r '(.motherboard.vendor // "unknown") + " " + (.motherboard.product // "unknown")' "$inv")"
    echo "Risk flags: $(jq -r '(.risk_flags // []) | join(", ")' "$inv")"
    if jq -e '.has_nvidia_rtx_turing_like == true or .has_rtx_2070 == true' "$inv" >/dev/null; then
      echo "[WARN] NVIDIA RTX/Turing detected: not a macOS acceleration path"
    fi
  else
    echo "[WARN] No inventory found. Run: sudo scripts/tripleboot_aio.sh scan"
  fi

  echo
  echo "=== Boot order ==="
  if have efibootmgr; then
    boot_order="$(efibootmgr 2>/dev/null | awk -F': ' '/BootOrder/ {print $2}' || true)"
    echo "BootOrder: ${boot_order:-unknown}"
    efibootmgr | grep -E '^Boot[0-9A-Fa-f]{4}' || true
    if [[ "$boot_order" == 0001,* ]]; then
      echo "[OK] Ubuntu appears first in current BootOrder"
    else
      echo "[WARN] Ubuntu does not appear first. Review with: sudo efibootmgr -v"
    fi
  else
    echo "[WARN] efibootmgr not installed"
  fi

  echo
  echo "=== Disk safety ==="
  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,PTTYPE,PARTTYPENAME,PARTLABEL,LABEL,MOUNTPOINTS,MODEL

  rootdisk="$(root_parent_disk || true)"
  if [[ -n "$rootdisk" ]]; then
    echo "[OK] Running root disk detected: $rootdisk"
  else
    echo "[WARN] Could not detect running root disk"
  fi

  mapfile -t data_partitions < <(lsblk -rpno NAME,PARTLABEL,LABEL | awk '$2 == "DATA" || $3 == "DATA" {print $1}' || true)
  if [[ "${#data_partitions[@]}" -gt 0 ]]; then
    echo "[WARN] DATA partition detected. Do not partition its parent disk unless you intend to wipe it:"
    local data_partition parent_disk
    for data_partition in "${data_partitions[@]}"; do
      parent_disk="$(lsblk -no PKNAME "$data_partition" 2>/dev/null | head -n1 || true)"
      if [[ -n "$parent_disk" && "$parent_disk" != /dev/* ]]; then
        parent_disk="/dev/$parent_disk"
      fi
      echo "DATA partition: $data_partition"
      echo "Parent disk: ${parent_disk:-unknown}"
    done
  fi

  echo
  echo "=== EFI backup status ==="
  latest_backup="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1 || true)"
  if [[ -n "$latest_backup" ]]; then
    efi_count="$(find "$latest_backup" -type f -iname '*.efi' 2>/dev/null | wc -l | tr -d ' ')"
    echo "Latest backup: $latest_backup"
    echo "EFI file count: $efi_count"
    if [[ "$efi_count" -gt 0 ]]; then
      echo "[OK] Latest EFI backup contains EFI loaders"
    else
      echo "[WARN] Latest EFI backup contains no EFI files"
    fi
  else
    echo "[WARN] No EFI backup found. Run: sudo scripts/tripleboot_aio.sh backup-efi"
  fi

  echo
  echo "=== Recommended next action ==="
  echo "Do not run partition from the installed Ubuntu unless intentionally wiping disks."
  echo "For now: keep using scan/analyze/backup-efi/boot-report/doctor until the final disk plan is locked."
}

main() {
  [[ $# -gt 0 ]] || { usage; exit 1; }
  local args=() cmd
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --force) FORCE=true; shift ;;
      --noninteractive) NONINTERACTIVE=true; shift ;;
      --no-banner) SHOW_BANNER=false; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [[ ${#args[@]} -gt 0 ]] || { usage; exit 1; }
  set -- "${args[@]}"
  cmd="$1"
  shift || true
  case "$cmd" in
    help|-h|--help) usage ;;
    plan) plan ;;
    install-deps) install_deps ;;
    install-refind) install_refind ;;
    scan) scan ;;
    analyze) analyze ;;
    doctor) doctor ;;
    preflight-partition) preflight_partition "$@" ;;
    installer-doctor) installer_doctor ;;
    usb-plan) usb_plan "$@" ;;
    download-ubuntu) download_ubuntu "$@" ;;
    verify-iso-sha256) verify_iso_sha256 "$@" ;;
    download-windows) download_windows "$@" ;;
    prepare-usb-dd) prepare_usb_dd "$@" ;;
    prepare-usb-ubuntu) prepare_usb_ubuntu "$@" ;;
    prepare-usb-windows) prepare_usb_windows "$@" ;;
    download-macos) download_macos "$@" ;;
    prepare-usb-macos) prepare_usb_macos "$@" ;;
    osx-kvm-doctor) osx_kvm_doctor "$@" ;;
    osx-kvm-clone) osx_kvm_clone "$@" ;;
    osx-kvm-fetch) osx_kvm_fetch "$@" ;;
    osx-kvm-convert) osx_kvm_convert "$@" ;;
    osx-kvm-create-disk) osx_kvm_create_disk "$@" ;;
    osx-kvm-boot) osx_kvm_boot "$@" ;;
    osx-kvm-offline-iso) osx_kvm_offline_iso "$@" ;;
    download-ventoy) download_ventoy "$@" ;;
    prepare-usb-ventoy) prepare_usb_ventoy "$@" ;;
    stage-tripleboot-usb) stage_tripleboot_usb "$@" ;;
    build-tripleboot-usb) build_tripleboot_usb "$@" ;;
    tripleboot-usb-status) tripleboot_usb_status "$@" ;;
    backup-efi) backup_efi ;;
    boot-report) boot_report ;;
    partition) partition_cmd "$@" ;;
    setup-swap) setup_swap "$@" ;;
    download-opencore) download_opencore "$@" ;;
    download-kexts) download_kexts ;;
    build-opencore-scaffold) build_opencore_scaffold "$@" ;;
    validate-opencore) validate_opencore ;;
    make-usb) make_usb "$@" ;;
    restore-efi) restore_efi "$@" ;;
    *) die "Unknown command: $cmd" ;;
  esac
}

main "$@"
