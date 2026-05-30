#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_ROOT/scripts/tripleboot_profile_engine.py"
AIO="$REPO_ROOT/scripts/tripleboot_aio.sh"
DEFAULT_PROFILE="$REPO_ROOT/profiles/pc-27pm.yml"

user_home() {
  local owner="${SUDO_USER:-${USER:-}}"
  local owner_home=""

  if [[ -n "$owner" && "$owner" != "root" ]]; then
    owner_home="$(getent passwd "$owner" | cut -d: -f6 || true)"
  fi

  if [[ -n "$owner_home" ]]; then
    printf '%s\n' "$owner_home"
  else
    printf '%s\n' "$HOME"
  fi
}

DEFAULT_OUTPUT="${TRIPLEBOOT_AUTONOMOUS_OUTPUT:-$(user_home)/tripleboot-aio/build/autonomous-payload}"

usage() {
  cat <<'EOF'
TripleBoot autonomous profile wrapper

Commands:
  validate [--profile FILE] [--strict]
  generate [--profile FILE] [--output-dir DIR]
  show-output [--output-dir DIR]
  stage-usb --usb-disk DISK [--profile FILE] [--output-dir DIR]
  status-usb --usb-disk DISK

Examples:
  scripts/tripleboot_autonomous.sh validate --profile profiles/pc-27pm.yml
  scripts/tripleboot_autonomous.sh generate --profile profiles/pc-27pm.yml
  sudo scripts/tripleboot_autonomous.sh stage-usb --usb-disk /dev/sdX --profile profiles/pc-27pm.yml
  sudo scripts/tripleboot_autonomous.sh status-usb --usb-disk /dev/sdX
EOF
}

need_python() {
  command -v python3 >/dev/null 2>&1 || {
    echo "[ERROR] python3 is required" >&2
    exit 1
  }
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "[ERROR] command must run with sudo/root" >&2
    exit 1
  fi
}

assert_disk() {
  local disk="$1"
  local typ=""
  [[ -b "$disk" ]] || { echo "[ERROR] Block device not found: $disk" >&2; exit 1; }
  typ="$(lsblk -dn -o TYPE "$disk" 2>/dev/null || true)"
  [[ "$typ" == "disk" ]] || { echo "[ERROR] Not a whole disk: $disk" >&2; exit 1; }
}

root_parent_disk() {
  local src=""
  local pk=""
  src="$(findmnt -n -o SOURCE / || true)"
  [[ "$src" == /dev/* ]] || return 0
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
  [[ -n "$pk" ]] && printf '/dev/%s\n' "$pk"
}

protect_running_root() {
  local disk="$1"
  local rootdisk=""
  rootdisk="$(root_parent_disk || true)"
  if [[ -n "$rootdisk" && "$disk" == "$rootdisk" ]]; then
    echo "[ERROR] Refusing to stage to running root disk: $disk" >&2
    exit 1
  fi
}

ventoy_data_partition() {
  local usb="$1"
  local part=""
  part="$(lsblk -rpno NAME,LABEL "$usb" 2>/dev/null | awk '$2 == "Ventoy" {print $1; exit}' || true)"
  if [[ -z "$part" ]]; then
    if [[ "$usb" =~ [0-9]$ ]]; then
      part="${usb}p1"
    else
      part="${usb}1"
    fi
  fi
  [[ -b "$part" ]] || { echo "[ERROR] Could not detect Ventoy data partition for $usb" >&2; exit 1; }
  printf '%s\n' "$part"
}

mount_ventoy_data() {
  local usb="$1"
  local part=""
  local mnt=""
  part="$(ventoy_data_partition "$usb")"
  mnt="$(mktemp -d)"
  echo "[INFO] Ventoy data partition: $part" >&2
  mount "$part" "$mnt"
  printf '%s\n' "$mnt"
}

cmd_validate() {
  local profile="$DEFAULT_PROFILE"
  local strict=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --strict) strict=true; shift ;;
      *) echo "[ERROR] Unknown validate arg: $1" >&2; exit 1 ;;
    esac
  done

  need_python
  if [[ "$strict" == true ]]; then
    python3 "$ENGINE" validate-profile --profile "$profile" --strict
  else
    python3 "$ENGINE" validate-profile --profile "$profile"
  fi
}

cmd_generate() {
  local profile="$DEFAULT_PROFILE"
  local output_dir="$DEFAULT_OUTPUT"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --output-dir) output_dir="$2"; shift 2 ;;
      *) echo "[ERROR] Unknown generate arg: $1" >&2; exit 1 ;;
    esac
  done

  need_python
  python3 "$ENGINE" generate-autonomous-payload \
    --profile "$profile" \
    --output-dir "$output_dir" \
    --repo-root "$REPO_ROOT"
}

cmd_show_output() {
  local output_dir="$DEFAULT_OUTPUT"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-dir) output_dir="$2"; shift 2 ;;
      *) echo "[ERROR] Unknown show-output arg: $1" >&2; exit 1 ;;
    esac
  done

  if [[ ! -d "$output_dir" ]]; then
    echo "[WARN] Output directory does not exist: $output_dir"
    exit 0
  fi

  find "$output_dir" -maxdepth 5 -type f | sort
}

cmd_status_usb() {
  local usb=""
  local mnt=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --usb-disk) usb="$2"; shift 2 ;;
      *) echo "[ERROR] Unknown status-usb arg: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "$usb" ]] || { echo "[ERROR] Missing --usb-disk" >&2; exit 1; }
  need_root
  assert_disk "$usb"

  echo "=== USB disk ==="
  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS,MODEL,TRAN "$usb"

  mnt="$(mount_ventoy_data "$usb")"

  echo
  echo "=== Autonomous payload files ==="
  find "$mnt" -maxdepth 6 -type f \
    \( -path '*/autoinstall/*' -o -path '*/ventoy/ventoy.json' -o -path '*/TripleBoot/profile.yml' -o -path '*/TripleBoot/README-AUTONOMOUS.txt' \) \
    -printf '%P\n' | sort

  echo
  echo "=== Required autonomous files ==="
  local required=(
    "ventoy/ventoy.json"
    "autoinstall/ubuntu/user-data.yml"
    "autoinstall/ubuntu/meta-data"
    "autoinstall/windows/Autounattend.xml"
    "TripleBoot/profile.yml"
    "TripleBoot/README-AUTONOMOUS.txt"
  )
  local path=""
  local missing=0
  for path in "${required[@]}"; do
    if [[ -f "$mnt/$path" ]]; then
      echo "[OK] $path"
    else
      echo "[MISSING] $path"
      missing=$((missing + 1))
    fi
  done

  umount "$mnt"
  rmdir "$mnt" || true

  if [[ "$missing" -gt 0 ]]; then
    echo "[ERROR] Autonomous payload incomplete: $missing missing file(s)" >&2
    exit 2
  fi

  echo "[OK] Autonomous USB payload complete"
}

cmd_stage_usb() {
  local usb=""
  local profile="$DEFAULT_PROFILE"
  local output_dir="$DEFAULT_OUTPUT"
  local mnt=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --usb-disk) usb="$2"; shift 2 ;;
      --profile) profile="$2"; shift 2 ;;
      --output-dir) output_dir="$2"; shift 2 ;;
      *) echo "[ERROR] Unknown stage-usb arg: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "$usb" ]] || { echo "[ERROR] Missing --usb-disk" >&2; exit 1; }
  need_root
  need_python
  assert_disk "$usb"
  protect_running_root "$usb"

  cmd_generate --profile "$profile" --output-dir "$output_dir"
  [[ -d "$output_dir" ]] || { echo "[ERROR] Payload output missing: $output_dir" >&2; exit 1; }

  mnt="$(mount_ventoy_data "$usb")"

  rsync -rltD --no-owner --no-group --no-perms --omit-dir-times --inplace "$output_dir"/ "$mnt"/
  sync
  umount "$mnt"
  rmdir "$mnt" || true

  echo "[OK] Autonomous payload staged to USB: $usb"
  echo "[OK] Staged files:"
  find "$output_dir" -maxdepth 5 -type f | sort

  cmd_status_usb --usb-disk "$usb"

  if [[ -x "$AIO" ]]; then
    echo
    echo "[INFO] USB status from AIO:"
    "$AIO" tripleboot-usb-status --usb-disk "$usb" || true
  fi
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    help|-h|--help) usage ;;
    validate) cmd_validate "$@" ;;
    generate) cmd_generate "$@" ;;
    show-output) cmd_show_output "$@" ;;
    stage-usb) cmd_stage_usb "$@" ;;
    status-usb) cmd_status_usb "$@" ;;
    *) echo "[ERROR] Unknown command: $cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
