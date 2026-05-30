#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_ROOT/scripts/tripleboot_profile_engine.py"
AIO="$REPO_ROOT/scripts/tripleboot_aio.sh"
DEFAULT_PROFILE="$REPO_ROOT/profiles/pc-27pm.yml"
DEFAULT_OUTPUT="${TRIPLEBOOT_AUTONOMOUS_OUTPUT:-$HOME/tripleboot-aio/build/autonomous-payload}"

usage() {
  cat <<'EOF'
TripleBoot autonomous profile wrapper

Commands:
  validate [--profile FILE] [--strict]
  generate [--profile FILE] [--output-dir DIR]
  show-output [--output-dir DIR]
  stage-usb --usb-disk DISK [--profile FILE] [--output-dir DIR]

Examples:
  scripts/tripleboot_autonomous.sh validate --profile profiles/pc-27pm.yml
  scripts/tripleboot_autonomous.sh generate --profile profiles/pc-27pm.yml
  sudo scripts/tripleboot_autonomous.sh stage-usb --usb-disk /dev/sdX --profile profiles/pc-27pm.yml
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
    echo "[ERROR] stage-usb must run with sudo/root" >&2
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

cmd_stage_usb() {
  local usb=""
  local profile="$DEFAULT_PROFILE"
  local output_dir="$DEFAULT_OUTPUT"
  local part=""
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

  part="$(ventoy_data_partition "$usb")"
  mnt="$(mktemp -d)"

  echo "[INFO] Ventoy data partition: $part"
  mount "$part" "$mnt"

  rsync -aHAX "$output_dir"/ "$mnt"/
  sync
  umount "$mnt"
  rmdir "$mnt" || true

  echo "[OK] Autonomous payload staged to USB: $usb"
  echo "[OK] Staged files:"
  find "$output_dir" -maxdepth 5 -type f | sort

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
    *) echo "[ERROR] Unknown command: $cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
