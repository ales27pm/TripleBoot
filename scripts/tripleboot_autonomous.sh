#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_ROOT/scripts/tripleboot_profile_engine.py"
DEFAULT_PROFILE="$REPO_ROOT/profiles/pc-27pm.yml"
DEFAULT_OUTPUT="${TRIPLEBOOT_AUTONOMOUS_OUTPUT:-$HOME/tripleboot-aio/build/autonomous-payload}"

usage() {
  cat <<'EOF'
TripleBoot autonomous profile wrapper

Commands:
  validate [--profile FILE] [--strict]
  generate [--profile FILE] [--output-dir DIR]
  show-output [--output-dir DIR]

Examples:
  scripts/tripleboot_autonomous.sh validate --profile profiles/pc-27pm.yml
  scripts/tripleboot_autonomous.sh generate --profile profiles/pc-27pm.yml
EOF
}

need_python() {
  command -v python3 >/dev/null 2>&1 || {
    echo "[ERROR] python3 is required" >&2
    exit 1
  }
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

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    help|-h|--help) usage ;;
    validate) cmd_validate "$@" ;;
    generate) cmd_generate "$@" ;;
    show-output) cmd_show_output "$@" ;;
    *) echo "[ERROR] Unknown command: $cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
