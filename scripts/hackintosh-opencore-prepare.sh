#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# hackintosh-opencore-prepare.sh
#
# Ubuntu/Linux OpenCore workspace + recovery USB preparer.
#
# What it does:
#   - Installs needed Linux packages.
#   - Downloads latest OpenCorePkg release.
#   - Downloads common Acidanthera kext releases.
#   - Creates EFI/OC structure.
#   - Copies OpenCore boot files and basic drivers.
#   - Downloads macOS Recovery files through OpenCore's macrecovery.py.
#   - Optionally formats a USB as GPT/FAT32 and stages EFI + recovery.
#
# What it does NOT do:
#   - Generate a final bootable config.plist for your exact motherboard.
#   - Generate SMBIOS serials.
#   - Patch ACPI automatically.
#   - Make RTX 2070 work. It will not.
#
# Usage:
#   chmod +x scripts/hackintosh-opencore-prepare.sh
#   scripts/hackintosh-opencore-prepare.sh --macos sequoia --workdir "$HOME/hackintosh"
#
# Optional USB creation, destructive:
#   sudo scripts/hackintosh-opencore-prepare.sh --macos sequoia --disk /dev/sdX --workdir "$HOME/hackintosh"
#
# macOS choices:
#   ventura | sonoma | sequoia | tahoe

MACOS="sequoia"
WORKDIR="${HOME}/hackintosh-opencore"
DISK=""
FORCE="false"

OC_REPO="acidanthera/OpenCorePkg"

KEXT_REPOS=(
  "acidanthera/Lilu"
  "acidanthera/VirtualSMC"
  "acidanthera/WhateverGreen"
  "acidanthera/AppleALC"
  "acidanthera/IntelMausi"
  "SongXiaoXi/AppleIGC"
)

REQUIRED_COMMANDS=(
  curl jq unzip git python3 find rsync
)

USB_COMMANDS=(
  lsblk umount wipefs sgdisk parted partprobe mkfs.vfat mount sync
)

log() {
  printf '\033[1;32m[+] %s\033[0m\n' "$*"
}

warn() {
  printf '\033[1;33m[!] %s\033[0m\n' "$*"
}

die() {
  printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF_USAGE
Usage:
  $0 [--macos ventura|sonoma|sequoia|tahoe] [--workdir PATH] [--disk /dev/sdX] [--force]

Examples:
  $0 --macos sequoia --workdir "\$HOME/hackintosh"
  sudo $0 --macos sequoia --disk /dev/sdX --workdir "\$HOME/hackintosh"

Options:
  --macos     Recovery version to download. Default: sequoia
  --workdir   Workspace directory. Default: \$HOME/hackintosh-opencore
  --disk      Optional USB disk to format. Example: /dev/sdX (sdX is also accepted)
  --force     Skip destructive USB confirmation prompt
EOF_USAGE
}

require_arg() {
  local flag="$1"
  local value="${2:-}"

  [[ -n "$value" && "$value" != --* ]] || die "Missing value for ${flag}"
}

normalize_disk_arg() {
  local disk="$1"

  if [[ "$disk" != /* ]]; then
    disk="/dev/$disk"
  fi

  printf '%s\n' "$disk"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --macos)
      require_arg "$1" "${2:-}"
      MACOS="$2"
      shift 2
      ;;
    --workdir)
      require_arg "$1" "${2:-}"
      WORKDIR="$2"
      shift 2
      ;;
    --disk)
      require_arg "$1" "${2:-}"
      DISK="$2"
      shift 2
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

case "$MACOS" in
  ventura|sonoma|sequoia|tahoe) ;;
  *) die "Unsupported --macos value: $MACOS" ;;
esac

if [[ -n "$DISK" ]]; then
  DISK="$(normalize_disk_arg "$DISK")"

  if [[ $EUID -ne 0 ]]; then
    die "USB formatting requires root. Re-run with sudo or omit --disk."
  fi
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  die "This script is intended for Linux/Ubuntu."
fi

missing_commands() {
  local command_name

  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      printf '%s\n' "$command_name"
    fi
  done
}

validate_usb_disk() {
  [[ -b "$DISK" ]] || die "$DISK is not a block device"

  local disk_type
  disk_type="$(lsblk -dnro TYPE -- "$DISK")"
  [[ "$disk_type" == "disk" ]] || die "$DISK must be a whole disk (TYPE=disk), not TYPE=${disk_type:-unknown}"
}

install_deps() {
  log "Checking dependencies"

  local required_commands=("${REQUIRED_COMMANDS[@]}")

  if [[ -n "$DISK" ]]; then
    required_commands+=("${USB_COMMANDS[@]}")
  fi

  local missing=()
  mapfile -t missing < <(missing_commands "${required_commands[@]}")

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "Dependencies already installed"
    return
  fi

  log "Installing missing dependencies: ${missing[*]}"

  if command -v apt-get >/dev/null 2>&1; then
    local apt_cmd=()

    if [[ $EUID -eq 0 ]]; then
      apt_cmd=(apt-get)
    elif command -v sudo >/dev/null 2>&1; then
      warn "Dependency installation requires root; using sudo for apt-get."
      apt_cmd=(sudo apt-get)
    else
      die "Missing dependencies: ${missing[*]}. Install them manually or re-run with sudo/root."
    fi

    "${apt_cmd[@]}" update
    "${apt_cmd[@]}" install -y \
      curl jq unzip git python3 \
      dosfstools exfatprogs gdisk parted util-linux rsync
  else
    die "Missing dependencies: ${missing[*]}. Only apt-based distros are automated here; install the missing tools manually."
  fi
}

latest_release_asset_url() {
  local repo="$1"
  local pattern="$2"

  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | jq -r --arg pattern "$pattern" '
      .assets[]
      | select(.name | test($pattern))
      | .browser_download_url
    ' \
    | head -n 1
}

download_zip() {
  local repo="$1"
  local pattern="$2"
  local out="$3"
  local url

  url="$(latest_release_asset_url "$repo" "$pattern")"

  if [[ -z "$url" || "$url" == "null" ]]; then
    die "Could not find release asset for ${repo} matching ${pattern}"
  fi

  log "Downloading ${repo}"
  curl -fL --retry 5 --retry-delay 2 "$url" -o "$out"
}

prepare_dirs() {
  log "Preparing workspace: $WORKDIR"

  mkdir -p "$WORKDIR"/{downloads,extract,usbroot}
  mkdir -p "$WORKDIR/EFI/BOOT"
  mkdir -p "$WORKDIR/EFI/OC/"{ACPI,Kexts,Drivers,Tools,Resources}
  mkdir -p "$WORKDIR/com.apple.recovery.boot"
}

extract_zip_clean() {
  local zip="$1"
  local dest="$2"

  rm -rf "$dest"
  mkdir -p "$dest"
  unzip -q "$zip" -d "$dest"
}

find_one() {
  local root="$1"
  local name="$2"

  find "$root" -name "$name" -print -quit
}

copy_opencore_files() {
  local oc_zip="$WORKDIR/downloads/OpenCorePkg.zip"
  local oc_dir="$WORKDIR/extract/OpenCorePkg"

  download_zip "$OC_REPO" 'OpenCore-.*-RELEASE\.zip$' "$oc_zip"
  extract_zip_clean "$oc_zip" "$oc_dir"

  local bootx64 opencore openruntime openhfsplus opencanopy sample
  bootx64="$(find_one "$oc_dir" "BOOTx64.efi")"
  opencore="$(find_one "$oc_dir" "OpenCore.efi")"
  openruntime="$(find_one "$oc_dir" "OpenRuntime.efi")"
  openhfsplus="$(find_one "$oc_dir" "OpenHfsPlus.efi")"
  opencanopy="$(find_one "$oc_dir" "OpenCanopy.efi")"
  sample="$(find_one "$oc_dir" "Sample.plist")"

  [[ -f "$bootx64" ]] || die "BOOTx64.efi not found"
  [[ -f "$opencore" ]] || die "OpenCore.efi not found"
  [[ -f "$openruntime" ]] || die "OpenRuntime.efi not found"
  [[ -f "$openhfsplus" ]] || die "OpenHfsPlus.efi not found"
  [[ -f "$sample" ]] || die "Sample.plist not found"

  cp -f "$bootx64" "$WORKDIR/EFI/BOOT/BOOTx64.efi"
  cp -f "$opencore" "$WORKDIR/EFI/OC/OpenCore.efi"
  cp -f "$openruntime" "$WORKDIR/EFI/OC/Drivers/OpenRuntime.efi"
  cp -f "$openhfsplus" "$WORKDIR/EFI/OC/Drivers/OpenHfsPlus.efi"

  if [[ -f "$opencanopy" ]]; then
    cp -f "$opencanopy" "$WORKDIR/EFI/OC/Drivers/OpenCanopy.efi"
  fi

  cp -f "$sample" "$WORKDIR/EFI/OC/config.sample.plist"
  cp -f "$sample" "$WORKDIR/EFI/OC/config.plist"

  log "OpenCore base files copied"
}

copy_kext_from_release() {
  local repo="$1"
  local name
  local zip
  local extract

  name="$(basename "$repo")"
  zip="$WORKDIR/downloads/${name}.zip"
  extract="$WORKDIR/extract/${name}"

  case "$repo" in
    SongXiaoXi/AppleIGC)
      download_zip "$repo" '^AppleIGC\.kext\.zip$' "$zip"
      ;;
    *)
      download_zip "$repo" '.*-RELEASE\.zip$' "$zip"
      ;;
  esac
  extract_zip_clean "$zip" "$extract"

  local kexts
  mapfile -t kexts < <(find "$extract" -name "*.kext" -type d)

  if [[ "${#kexts[@]}" -eq 0 ]]; then
    warn "No .kext found in ${repo}"
    return
  fi

  for kext in "${kexts[@]}"; do
    local base
    base="$(basename "$kext")"

    case "$base" in
      *Debug*|*DEBUG*)
        continue
        ;;
    esac

    rsync -a "$kext" "$WORKDIR/EFI/OC/Kexts/"
    log "Added kext: $base"
  done
}

download_kexts() {
  log "Downloading common kexts"

  for repo in "${KEXT_REPOS[@]}"; do
    copy_kext_from_release "$repo"
  done

  cat > "$WORKDIR/EFI/OC/Kexts/README.md" <<'EOF_KEXTS'
Kext notes:
- Lilu.kext: dependency used by many patches.
- VirtualSMC.kext: required SMC emulator.
- WhateverGreen.kext: GPU-related patches. Does NOT make RTX 2070 supported.
- AppleALC.kext: audio codec support.
- IntelMausi.kext: Intel Ethernet support for many Intel LAN chips.
- AppleIGC.kext: Intel I225/I226 2.5Gb Ethernet support.

Do not enable every kext blindly. Match your exact hardware.
EOF_KEXTS
}

download_tools() {
  log "Cloning useful config/ACPI tools"

  if [[ ! -d "$WORKDIR/tools/ProperTree/.git" ]]; then
    mkdir -p "$WORKDIR/tools"
    git clone --depth 1 https://github.com/corpnewt/ProperTree.git "$WORKDIR/tools/ProperTree"
  fi

  if [[ ! -d "$WORKDIR/tools/SSDTTime/.git" ]]; then
    git clone --depth 1 https://github.com/corpnewt/SSDTTime.git "$WORKDIR/tools/SSDTTime"
  fi
}

download_recovery() {
  log "Downloading macOS Recovery: $MACOS"

  local macrecovery
  macrecovery="$(find_one "$WORKDIR/extract/OpenCorePkg" "macrecovery.py")"
  [[ -f "$macrecovery" ]] || die "macrecovery.py not found inside OpenCorePkg"

  pushd "$WORKDIR/com.apple.recovery.boot" >/dev/null

  case "$MACOS" in
    ventura)
      python3 "$macrecovery" -b Mac-B4831CEBD52A0C4C -m 00000000000000000 download
      ;;
    sonoma)
      python3 "$macrecovery" -b Mac-827FAC58A8FDFA22 -m 00000000000000000 download
      ;;
    sequoia)
      python3 "$macrecovery" -b Mac-7BA5B2D9E42DDD94 -m 00000000000000000 download
      ;;
    tahoe)
      python3 "$macrecovery" -b Mac-CFF7D910A743CAAF -m 00000000000000000 -os latest download
      ;;
  esac

  popd >/dev/null

  log "Recovery files downloaded into com.apple.recovery.boot"
}

write_next_steps() {
  cat > "$WORKDIR/NEXT_STEPS.md" <<EOF_NEXT_STEPS
# OpenCore next steps

Generated workspace:

\`\`\`
$WORKDIR
├── EFI
│   ├── BOOT
│   └── OC
└── com.apple.recovery.boot
\`\`\`

## Critical hardware note

Your RTX 2070 is unsupported in macOS. Do not waste days trying to patch it.
Use a supported AMD GPU for a real install.

## Before booting

1. Build hardware-specific ACPI:
   - SSDT-PLUG
   - SSDT-EC-USBX
   - SSDT-AWAC or RTC fix if required
   - USB map before macOS 11.3+ whenever possible

2. Edit:
   EFI/OC/config.plist

3. Use ProperTree Clean Snapshot:
   \`\`\`
   python3 "$WORKDIR/tools/ProperTree/ProperTree.py"
   \`\`\`

4. Validate with OpenCore's ocvalidate from the OpenCorePkg Utilities folder.

5. Generate real SMBIOS values with GenSMBIOS, not included automatically here.
   Do not reuse serials from public EFIs.

6. BIOS rough targets:
   - UEFI boot enabled
   - CSM disabled
   - Secure Boot disabled
   - VT-d disabled unless configured properly
   - CFG Lock disabled if available
   - Above 4G Decoding often enabled
   - SATA mode AHCI
   - XHCI handoff enabled

## This script intentionally does not use random prebuilt EFIs

Prebuilt EFIs are how people end up with stacked patches, fake fixes, broken USB maps,
bad serials, and mystery boot failures.
EOF_NEXT_STEPS
}

format_usb_and_copy() {
  validate_usb_disk

  warn "This will DESTROY all data on: $DISK"
  lsblk "$DISK"

  if [[ "$FORCE" != "true" ]]; then
    read -r -p "Type EXACTLY 'ERASE ${DISK}' to continue: " confirm
    [[ "$confirm" == "ERASE ${DISK}" ]] || die "Aborted"
  fi

  log "Unmounting existing partitions"
  while read -r part; do
    [[ -n "$part" ]] || continue
    umount "$part" 2>/dev/null || true
  done < <(lsblk -lnpo NAME "$DISK" | tail -n +2 || true)

  log "Wiping partition table"
  wipefs -a "$DISK"
  sgdisk --zap-all "$DISK"

  log "Creating GPT with one FAT32 OPENCORE partition"
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart ESP fat32 1MiB 100%
  parted -s "$DISK" set 1 esp on

  partprobe "$DISK"
  sleep 2

  local part="${DISK}1"
  if [[ "$DISK" =~ nvme|mmcblk ]]; then
    part="${DISK}p1"
  fi

  [[ -b "$part" ]] || die "Partition not found: $part"

  log "Formatting $part as FAT32"
  mkfs.vfat -F 32 -n OPENCORE "$part"

  local mnt
  mnt="$(mktemp -d)"

  mount "$part" "$mnt"

  log "Copying EFI and recovery files to USB"
  rsync -a "$WORKDIR/EFI" "$mnt/"
  rsync -a "$WORKDIR/com.apple.recovery.boot" "$mnt/"

  sync
  umount "$mnt"
  rmdir "$mnt"

  log "USB staged successfully: $DISK"
}

main() {
  install_deps

  if [[ -n "$DISK" ]]; then
    validate_usb_disk
  fi

  prepare_dirs
  copy_opencore_files
  download_kexts
  download_tools
  download_recovery
  write_next_steps

  if [[ -n "$DISK" ]]; then
    format_usb_and_copy
  fi

  log "Done"
  echo
  echo "Workspace:"
  echo "  $WORKDIR"
  echo
  echo "Read:"
  echo "  $WORKDIR/NEXT_STEPS.md"
  echo
  echo "EFI path:"
  echo "  $WORKDIR/EFI"
}

main
