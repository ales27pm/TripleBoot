#!/usr/bin/env bash
# TripleBoot AIO — guarded UEFI/GPT helper for Ubuntu + Windows + OpenCore/macOS experiments.
# It automates only the safe/repeatable parts: scan, report, EFI backup, two-disk partitioning,
# swapfile setup, OpenCore scaffold download/generation, validation hooks, and USB EFI creation.
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2026.05.26"
SCRIPT_NAME="$(basename "$0")"
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

if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

mkdir -p "$WORKDIR" "$BACKUP_ROOT" "$INVENTORY_DIR" "$BUILD_DIR" "$DOWNLOAD_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/tripleboot-$(date +%Y%m%d-%H%M%S).log"

log(){ printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*" >> "$LOG_FILE"; }
info(){ printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; log "INFO $*"; }
warn(){ printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; log "WARN $*"; }
die(){ printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; log "ERROR $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run with sudo/root."; }
is_uefi(){ [[ -d /sys/firmware/efi ]]; }
assert_uefi(){ is_uefi || die "System is not booted in UEFI mode. Reboot installer/live USB in UEFI mode."; }
run(){ log "RUN $*"; if $DRY_RUN; then printf '%s[DRY-RUN]%s %s\n' "$BLUE" "$RESET" "$*"; else "$@"; fi; }
require(){ have "$1" || die "Missing command: $1"; }


tripleboot_banner(){
  cat <<'EOF'
████████╗██████╗ ██╗██████╗ ██╗     ███████╗██████╗  ██████╗  ██████╗ ████████╗
╚══██╔══╝██╔══██╗██║██╔══██╗██║     ██╔════╝██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝
   ██║   ██████╔╝██║██████╔╝██║     █████╗  ██████╔╝██║   ██║██║   ██║   ██║   
   ██║   ██╔══██╗██║██╔═══╝ ██║     ██╔══╝  ██╔══██╗██║   ██║██║   ██║   ██║   
   ██║   ██║  ██║██║██║     ███████╗███████╗██████╔╝╚██████╔╝╚██████╔╝   ██║   
   ╚═╝   ╚═╝  ╚═╝╚═╝╚═╝     ╚══════╝╚══════╝╚═════╝  ╚═════╝  ╚═════╝    ╚═╝   
    UEFI / GPT / OpenCore Lab Assistant  ::  PLAN • SCAN • ANALYZE • SAFEGUARD
EOF
}

confirm(){
  local token="$1" msg="$2"
  $NONINTERACTIVE && die "Confirmation required but --noninteractive is set: $msg"
  printf '%s\nType %s to continue: ' "$msg" "$token"
  local answer; read -r answer
  [[ "$answer" == "$token" ]] || die "Aborted."
}

part_name(){
  local disk="$1" num="$2"
  [[ "$disk" =~ [0-9]$ ]] && echo "${disk}p${num}" || echo "${disk}${num}"
}

root_parent_disk(){
  local src pk
  src="$(findmnt -n -o SOURCE / || true)"
  [[ "$src" == /dev/* ]] || return 0
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
  [[ -n "$pk" ]] && echo "/dev/$pk"
}

assert_disk(){
  local d="$1"
  [[ -b "$d" ]] || die "Block device not found: $d"
  [[ "$(lsblk -dn -o TYPE "$d" 2>/dev/null || true)" == "disk" ]] || die "$d is not a whole disk. Use /dev/nvme0n1, not a partition."
}

protect_running_root(){
  local target="$1" rootdisk
  rootdisk="$(root_parent_disk || true)"
  if [[ -n "$rootdisk" && "$target" == "$rootdisk" && "$FORCE" != true ]]; then
    die "Refusing to partition the running root disk: $target. Boot from a live USB or pass --force only if intentional."
  fi
}

unmount_disk(){
  local d="$1" p m
  while read -r p; do
    [[ -n "$p" ]] || continue
    while read -r m; do [[ -n "$m" ]] && run umount "$m" || true; done < <(lsblk -lnpo MOUNTPOINTS "$p" 2>/dev/null | tr ' ' '\n' | sed '/^$/d')
  done < <(lsblk -lnpo NAME "$d" | tail -n +2 || true)
}

usage(){
  cat <<EOF
${BOLD}TripleBoot AIO v$VERSION${RESET}

$(tripleboot_banner)

Commands:
  plan
  install-deps
  scan
  analyze
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

Default layout:
  Disk A: 1 GiB EFI + rest Ubuntu ext4.
  Disk B: 1 GiB EFI + 16 MiB MSR + $WINDOWS_SIZE Windows NTFS + rest macOS APFS placeholder.
EOF
}

plan(){
  cat <<EOF
$(tripleboot_banner)

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
EOF
}

install_deps(){
  need_root
  have apt-get || die "Only apt-based systems are automated here."
  run env DEBIAN_FRONTEND=noninteractive apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y bash coreutils util-linux gawk sed grep findutils file jq curl wget unzip zip git rsync gdisk parted dosfstools e2fsprogs ntfs-3g efibootmgr mokutil pciutils usbutils dmidecode lshw hwinfo acpica-tools fwupd nvme-cli qemu-utils qemu-system-x86 ovmf python3 python3-pip alsa-utils refind shellcheck || true
}

scan(){
  need_root
  mkdir -p "$INVENTORY_DIR/raw" "$INVENTORY_DIR/parsed"
  local r="$INVENTORY_DIR/raw"
  run bash -c "lscpu -J > '$r/lscpu.json'" || true
  run bash -c "grep -i 'model name' /proc/cpuinfo | sort -u > '$r/cpu_model.txt'" || true
  run bash -c "lspci -nnk > '$r/lspci_nnk.txt'" || true
  run bash -c "lspci -tv > '$r/lspci_tree.txt'" || true
  run bash -c "lsusb > '$r/lsusb.txt'" || true
  run bash -c "lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,PTTYPE,PARTTYPENAME,PARTLABEL,PARTUUID,UUID,MOUNTPOINTS,MODEL,SERIAL --json > '$r/lsblk.json'" || true
  run bash -c "dmidecode -t bios -t system -t baseboard -t processor > '$r/dmidecode.txt'" || true
  run bash -c "efibootmgr -v > '$r/efibootmgr.txt'" || true
  run bash -c "mokutil --sb-state > '$r/mokutil.txt'" || true
  run bash -c "nvme list -o json > '$r/nvme_list.json'" || true
  run bash -c "aplay -l > '$r/aplay.txt'" || true
  if have acpidump; then
    run bash -c "acpidump -b -o '$r/acpi.dump'" || true
    if [[ -f "$r/acpi.dump" ]] && have acpixtract; then mkdir -p "$r/acpi"; run bash -c "cd '$r/acpi' && acpixtract '../acpi.dump'" || true; fi
  fi
  python3 - "$r" "$INVENTORY_DIR/parsed/inventory.json" <<'PY'
import json, pathlib, re, sys, datetime
root = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2])
def text(name):
    p = root/name
    return p.read_text(errors='ignore') if p.exists() else ''
def js(name):
    try: return json.loads((root/name).read_text(errors='ignore'))
    except Exception: return {}
def lines(pattern, src): return [x.strip() for x in src.splitlines() if re.search(pattern, x, re.I)]
lspci=text('lspci_nnk.txt'); dmi=text('dmidecode.txt'); mok=text('mokutil.txt')
def dmi_field(section, key):
    active=False
    for ln in dmi.splitlines():
        if section.lower() in ln.lower(): active=True
        elif active and ln and not ln.startswith((' ', '\t')): active=False
        if active:
            m=re.match(r'\s*'+re.escape(key)+r':\s*(.*)', ln)
            if m: return m.group(1).strip()
    return None
gpus=lines(r'(VGA|3D|Display)', lspci)
inv={
 'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'cpu_model': (text('cpu_model.txt').splitlines() or ['unknown'])[0],
 'motherboard': {'vendor': dmi_field('Base Board Information','Manufacturer'), 'product': dmi_field('Base Board Information','Product Name')},
 'bios': {'vendor': dmi_field('BIOS Information','Vendor'), 'version': dmi_field('BIOS Information','Version'), 'date': dmi_field('BIOS Information','Release Date')},
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
PY
  info "Scan complete: $INVENTORY_DIR"
}

analyze(){
  local inv="$INVENTORY_DIR/parsed/inventory.json"
  [[ -f "$inv" ]] || die "Run scan first."
  require jq
  local report="$WORKDIR/TRIPLEBOOT_REPORT.md"
  cat > "$report" <<EOF
# TripleBoot Analysis

Generated: $(date --iso-8601=seconds)

## Detected

- CPU: $(jq -r '.cpu_model' "$inv")
- Board: $(jq -r '(.motherboard.vendor // "unknown") + " " + (.motherboard.product // "unknown")' "$inv")
- UEFI booted: $(jq -r '.booted_uefi' "$inv")
- Secure Boot: $(jq -r '.secure_boot // "unknown"' "$inv")
- Risk flags: $(jq -r '.risk_flags | join(", ")' "$inv")

## GPU

$(if jq -e '.has_rtx_2070 or .has_nvidia_rtx_turing_like' "$inv" >/dev/null; then echo 'NVIDIA RTX/Turing detected. Treat macOS bare-metal acceleration as unsupported. Use iGPU/AMD or lab/VM mode.'; else echo 'No RTX/Turing flag detected. Still verify GPU support manually.'; fi)

## Next actions

1. Run backup-efi.
2. Confirm disk names with boot-report.
3. Partition only from a live USB or with full awareness of root disk protection.
4. Install Windows, then Ubuntu, then test OpenCore from USB first.
EOF
  cat "$report"
}

detect_esps(){
  lsblk -rpno NAME,TYPE,FSTYPE,PARTTYPE,PARTLABEL,LABEL | awk '$2=="part" && (tolower($4) ~ /c12a7328/ || $3=="vfat" || $5 ~ /EFI/ || $6 ~ /EFI/) {print $1}' | sort -u
}

backup_efi(){
  need_root; require rsync; require mount; require umount
  local dest="$BACKUP_ROOT/efi-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dest"
  mapfile -t esps < <(detect_esps)
  [[ ${#esps[@]} -gt 0 ]] || die "No EFI partitions detected."
  for esp in "${esps[@]}"; do
    local mnt safe; mnt="$(mktemp -d)"; safe="$(echo "$esp" | sed 's#[/:]#_#g')"; mkdir -p "$dest/$safe"
    if run mount -o ro "$esp" "$mnt"; then run rsync -aHAX --numeric-ids "$mnt"/ "$dest/$safe"/; run umount "$mnt"; fi
    rmdir "$mnt" || true
  done
  info "EFI backup: $dest"
}

boot_report(){
  need_root
  echo "=== UEFI ==="; is_uefi && echo yes || echo no; have mokutil && mokutil --sb-state || true
  echo; echo "=== Disks ==="; lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,PTTYPE,PARTTYPENAME,PARTLABEL,LABEL,MOUNTPOINTS,MODEL
  echo; echo "=== Boot entries ==="; have efibootmgr && efibootmgr -v || true
  echo; echo "=== EFI loaders ==="
  mapfile -t esps < <(detect_esps)
  for esp in "${esps[@]:-}"; do
    local mnt; mnt="$(mktemp -d)"; echo "--- $esp ---"
    if mount -o ro "$esp" "$mnt"; then find "$mnt" -maxdepth 6 -type f -iname '*.efi' | sed "s#^$mnt##" | sort; umount "$mnt"; fi
    rmdir "$mnt" || true
  done
}

partition_cmd(){
  need_root; assert_uefi; require sgdisk; require wipefs; require partprobe; require mkfs.vfat; require mkfs.ext4
  local ubuntu="" winmac=""
  while [[ $# -gt 0 ]]; do case "$1" in --ubuntu-disk) ubuntu="$2"; shift 2;; --winmac-disk) winmac="$2"; shift 2;; --yes-destroy) YES_DESTROY=true; shift;; *) die "Unknown partition arg: $1";; esac; done
  [[ -n "$ubuntu" && -n "$winmac" ]] || die "Both --ubuntu-disk and --winmac-disk are required."
  [[ "$ubuntu" != "$winmac" ]] || die "Disks must be different."
  assert_disk "$ubuntu"; assert_disk "$winmac"; protect_running_root "$ubuntu"; protect_running_root "$winmac"
  $YES_DESTROY || die "Add --yes-destroy for destructive partitioning."
  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,LABEL,MOUNTPOINTS,MODEL
  confirm DESTROY "This will wipe $ubuntu and $winmac."

  unmount_disk "$ubuntu"; run sgdisk --zap-all "$ubuntu"; run wipefs -af "$ubuntu"; run partprobe "$ubuntu"; sleep 2
  run sgdisk -n 1:1MiB:+"$EFI_SIZE" -t 1:EF00 -c 1:UBUNTU_EFI -n 2:0:0 -t 2:8304 -c 2:UBUNTU_ROOT "$ubuntu"
  run partprobe "$ubuntu"; sleep 2
  run mkfs.vfat -F32 -n UBUNTU_EFI "$(part_name "$ubuntu" 1)"
  run mkfs.ext4 -F -L UBUNTU_ROOT "$(part_name "$ubuntu" 2)"

  unmount_disk "$winmac"; run sgdisk --zap-all "$winmac"; run wipefs -af "$winmac"; run partprobe "$winmac"; sleep 2
  run sgdisk -n 1:1MiB:+"$EFI_SIZE" -t 1:EF00 -c 1:WINMAC_EFI -n 2:0:+16MiB -t 2:0C01 -c 2:MSR -n 3:0:+"$WINDOWS_SIZE" -t 3:0700 -c 3:WINDOWS -n 4:0:0 -t 4:AF0A -c 4:MACOS_APFS "$winmac"
  run partprobe "$winmac"; sleep 2
  run mkfs.vfat -F32 -n WINMAC_EFI "$(part_name "$winmac" 1)"
  have mkfs.ntfs && run mkfs.ntfs -f -L WINDOWS "$(part_name "$winmac" 3)" || warn "mkfs.ntfs missing; Windows installer can format partition 3."
  warn "macOS/APFS placeholder is intentionally unformatted."
}

setup_swap(){
  need_root; require mkswap; require swapon
  local size="$UBUNTU_SWAP_SIZE" file="/swapfile"
  while [[ $# -gt 0 ]]; do case "$1" in --size) size="$2"; shift 2;; --file) file="$2"; shift 2;; *) die "Unknown setup-swap arg: $1";; esac; done
  run swapoff "$file" 2>/dev/null || true
  have fallocate && run fallocate -l "$size" "$file" || run dd if=/dev/zero of="$file" bs=1M count=32768 status=progress
  run chmod 600 "$file"; run mkswap "$file"; run swapon "$file"
  grep -q "^$file " /etc/fstab || echo "$file none swap sw 0 0" >> /etc/fstab
  swapon --show
}

github_latest_asset_url(){
  local repo="$1" regex="$2"; require curl; require jq
  curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | jq -r --arg re "$regex" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1
}

download_url(){ local url="$1" out="$2"; [[ -n "$url" && "$url" != null ]] || die "Empty URL"; mkdir -p "$(dirname "$out")"; [[ -f "$out" ]] || run curl -L --fail --retry 3 -o "$out" "$url"; }

download_opencore(){
  local version=latest url out
  while [[ $# -gt 0 ]]; do case "$1" in --version) version="$2"; shift 2;; *) die "Unknown download-opencore arg: $1";; esac; done
  if [[ "$version" == latest ]]; then url="$(github_latest_asset_url acidanthera/OpenCorePkg 'RELEASE.*\.zip$|OpenCore.*RELEASE.*\.zip$')"; out="$DOWNLOAD_DIR/opencore-latest.zip"; else url="https://github.com/acidanthera/OpenCorePkg/releases/download/${version}/OpenCore-${version}-RELEASE.zip"; out="$DOWNLOAD_DIR/opencore-${version}.zip"; fi
  download_url "$url" "$out"; info "OpenCore: $out"
}

download_kexts(){
  mkdir -p "$DOWNLOAD_DIR/kexts"
  local specs=("acidanthera/Lilu:Lilu.*RELEASE.*\.zip$" "acidanthera/VirtualSMC:VirtualSMC.*RELEASE.*\.zip$" "acidanthera/WhateverGreen:WhateverGreen.*RELEASE.*\.zip$" "acidanthera/AppleALC:AppleALC.*RELEASE.*\.zip$" "acidanthera/IntelMausi:IntelMausi.*RELEASE.*\.zip$" "acidanthera/NVMeFix:NVMeFix.*RELEASE.*\.zip$")
  for spec in "${specs[@]}"; do local repo="${spec%%:*}" regex="${spec#*:}" name="${repo##*/}" url; url="$(github_latest_asset_url "$repo" "$regex" || true)"; [[ -n "$url" ]] && download_url "$url" "$DOWNLOAD_DIR/kexts/$name.zip" || warn "No asset for $repo"; done
}

extract_zip(){ rm -rf "$2"; mkdir -p "$2"; run unzip -q "$1" -d "$2"; }

build_opencore_scaffold(){
  local oc_zip="" smbios="iMac20,1" gpu_policy=none
  while [[ $# -gt 0 ]]; do case "$1" in --oc-zip) oc_zip="$2"; shift 2;; --smbios) smbios="$2"; shift 2;; --gpu-policy) gpu_policy="$2"; shift 2;; *) die "Unknown build arg: $1";; esac; done
  [[ -n "$oc_zip" ]] || oc_zip="$DOWNLOAD_DIR/opencore-latest.zip"
  [[ -f "$oc_zip" ]] || die "OpenCore zip not found. Run download-opencore."
  rm -rf "$BUILD_DIR/ocpkg" "$BUILD_DIR/EFI"; mkdir -p "$BUILD_DIR/EFI/BOOT" "$BUILD_DIR/EFI/OC"/{ACPI,Drivers,Kexts,Tools,Resources}
  extract_zip "$oc_zip" "$BUILD_DIR/ocpkg"
  local ocroot bootroot sample
  ocroot="$(find "$BUILD_DIR/ocpkg" -type d -path '*/X64/EFI/OC' | head -n1 || true)"; [[ -n "$ocroot" ]] || die "Cannot find X64/EFI/OC."
  bootroot="${ocroot%/OC}/BOOT"
  cp -a "$bootroot/BOOTx64.efi" "$BUILD_DIR/EFI/BOOT/"; cp -a "$ocroot/OpenCore.efi" "$BUILD_DIR/EFI/OC/"
  cp -a "$ocroot/Drivers/OpenRuntime.efi" "$BUILD_DIR/EFI/OC/Drivers/" 2>/dev/null || true
  cp -a "$ocroot/Drivers/OpenHfsPlus.efi" "$BUILD_DIR/EFI/OC/Drivers/" 2>/dev/null || true
  cp -a "$ocroot/Tools/ResetNvramEntry.efi" "$BUILD_DIR/EFI/OC/Tools/" 2>/dev/null || true
  cp -a "$ocroot/Tools/OpenShell.efi" "$BUILD_DIR/EFI/OC/Tools/" 2>/dev/null || true
  for z in "$DOWNLOAD_DIR"/kexts/*.zip; do [[ -f "$z" ]] || continue; local tmp="$BUILD_DIR/kexttmp/$(basename "$z" .zip)"; extract_zip "$z" "$tmp"; find "$tmp" -type d -name '*.kext' ! -path '*Debug*' -maxdepth 8 -exec cp -a {} "$BUILD_DIR/EFI/OC/Kexts/" \; ; done
  sample="$(find "$BUILD_DIR/ocpkg" -type f -name Sample.plist | head -n1 || true)"
  [[ -n "$sample" ]] && cp "$sample" "$BUILD_DIR/Sample.plist"
  python3 - "$BUILD_DIR" "$smbios" "$gpu_policy" <<'PY'
import plistlib, pathlib, sys, uuid
build=pathlib.Path(sys.argv[1]); smbios=sys.argv[2]; gpu=sys.argv[3]
sample=build/'Sample.plist'; out=build/'EFI/OC/config.plist'
if sample.exists(): cfg=plistlib.load(sample.open('rb'))
else: cfg={'ACPI':{'Add':[]},'Kernel':{'Add':[]},'UEFI':{'Drivers':[]},'Misc':{'Security':{},'Tools':[]},'NVRAM':{'Add':{}},'PlatformInfo':{'Generic':{}},'DeviceProperties':{'Add':{},'Delete':{}}}
def ensure(*keys):
    cur=cfg
    for k in keys: cur=cur.setdefault(k,{})
    return cur
cfg.setdefault('Kernel',{})['Add']=[{'Arch':'Any','BundlePath':p.name,'Comment':p.name,'Enabled':True,'ExecutablePath':('Contents/MacOS/'+next((p/'Contents/MacOS').iterdir()).name if (p/'Contents/MacOS').exists() and list((p/'Contents/MacOS').iterdir()) else ''),'MaxKernel':'','MinKernel':'','PlistPath':'Contents/Info.plist'} for p in sorted((build/'EFI/OC/Kexts').glob('*.kext'))]
cfg.setdefault('UEFI',{})['Drivers']=[{'Arguments':'','Comment':p.name,'Enabled':True,'LoadEarly':False,'Path':p.name} for p in sorted((build/'EFI/OC/Drivers').glob('*.efi'))]
sec=ensure('Misc','Security'); sec['Vault']='Optional'; sec['ScanPolicy']=0; sec['SecureBootModel']='Disabled'
nv=ensure('NVRAM','Add').setdefault('7C436110-AB2A-4BBB-A880-FE41995C9F82',{})
args='-v keepsyms=1 debug=0x100' + (' -wegnoegpu' if gpu=='disable-nvidia' else '')
nv['boot-args']=args; nv['prev-lang:kbd']='fr-CA:0'
pi=ensure('PlatformInfo','Generic'); pi['SystemProductName']=smbios; pi.setdefault('SystemUUID',str(uuid.uuid4()).upper()); pi.setdefault('SystemSerialNumber','REPLACE_WITH_VALID_SERIAL'); pi.setdefault('MLB','REPLACE_WITH_VALID_MLB'); pi.setdefault('ROM',b'\0'*6)
out.parent.mkdir(parents=True, exist_ok=True); plistlib.dump(cfg,out.open('wb'),sort_keys=False)
PY
  cat > "$BUILD_DIR/manual-review-checklist.md" <<EOF
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
EOF
  info "OpenCore scaffold: $BUILD_DIR/EFI"
}

validate_opencore(){ local cfg="$BUILD_DIR/EFI/OC/config.plist"; [[ -f "$cfg" ]] || die "Missing $cfg"; local v; v="$(find "$BUILD_DIR/ocpkg" -type f -name ocvalidate 2>/dev/null | head -n1 || true)"; [[ -n "$v" ]] || die "ocvalidate not found. Build scaffold first."; chmod +x "$v"; run "$v" "$cfg"; }

make_usb(){
  need_root; assert_uefi
  local usb=""
  while [[ $# -gt 0 ]]; do case "$1" in --usb-disk) usb="$2"; shift 2;; --yes-destroy) YES_DESTROY=true; shift;; *) die "Unknown make-usb arg: $1";; esac; done
  assert_disk "$usb"; [[ -d "$BUILD_DIR/EFI" ]] || die "Build OpenCore scaffold first."; $YES_DESTROY || die "Add --yes-destroy."
  confirm WIPEUSB "This will wipe USB disk $usb."
  unmount_disk "$usb"; run sgdisk --zap-all "$usb"; run wipefs -af "$usb"; run sgdisk -n 1:1MiB:0 -t 1:0700 -c 1:OPENCORE_USB "$usb"; run partprobe "$usb"; sleep 2
  local p m; p="$(part_name "$usb" 1)"; run mkfs.vfat -F32 -n OPENCORE "$p"; m="$(mktemp -d)"; run mount "$p" "$m"; run rsync -aHAX "$BUILD_DIR/EFI" "$m"/; sync; run umount "$m"; rmdir "$m" || true
}

restore_efi(){
  need_root; require rsync
  local backup="" esp=""
  while [[ $# -gt 0 ]]; do case "$1" in --backup-dir) backup="$2"; shift 2;; --esp) esp="$2"; shift 2;; --yes-destroy) YES_DESTROY=true; shift;; *) die "Unknown restore arg: $1";; esac; done
  [[ -d "$backup" && -b "$esp" ]] || die "Need --backup-dir DIR and --esp PARTITION"; $YES_DESTROY || die "Add --yes-destroy."
  confirm RESTORE "This will overwrite files on $esp from $backup."
  local m; m="$(mktemp -d)"; run mount "$esp" "$m"; run rsync -aHAX --delete "$backup"/ "$m"/; sync; run umount "$m"; rmdir "$m" || true
}

parse_globals(){
  local out=()
  while [[ $# -gt 0 ]]; do case "$1" in --dry-run) DRY_RUN=true; shift;; --force) FORCE=true; shift;; --noninteractive) NONINTERACTIVE=true; shift;; *) out+=("$1"); shift;; esac; done
  printf '%s\n' "${out[@]}"
}

main(){
  [[ $# -gt 0 ]] || { usage; exit 1; }
  mapfile -t argv < <(parse_globals "$@"); set -- "${argv[@]}"
  local cmd="$1"; shift || true
  case "$cmd" in
    help|-h|--help) usage;; plan) plan;; install-deps) install_deps;; scan) scan;; analyze) analyze;; backup-efi) backup_efi;; boot-report) boot_report;; partition) partition_cmd "$@";; setup-swap) setup_swap "$@";; download-opencore) download_opencore "$@";; download-kexts) download_kexts;; build-opencore-scaffold) build_opencore_scaffold "$@";; validate-opencore) validate_opencore;; make-usb) make_usb "$@";; restore-efi) restore_efi "$@";; *) die "Unknown command: $cmd";;
  esac
}
main "$@"
