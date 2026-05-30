#!/usr/bin/env python3
"""TripleBoot autonomous profile engine.

Generates the files required for the Ventoy-based autonomous installer layer:
- Ubuntu autoinstall user-data
- Ubuntu meta-data
- Windows Autounattend.xml
- Ventoy ventoy.json auto_install mapping
- Profile snapshot copied to the USB payload

This tool is intentionally conservative. It does not partition disks and does not
write USB devices. The Bash AIO orchestrator remains responsible for destructive
operations and confirmations.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict

try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None


class ProfileError(RuntimeError):
    pass


def read_yaml(path: Path) -> Dict[str, Any]:
    if yaml is None:
        raise ProfileError("PyYAML is required. Install with: python3 -m pip install pyyaml")
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise ProfileError(f"Profile is not a mapping: {path}")
    return data


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def lookup(data: Dict[str, Any], dotted: str, default: str = "") -> str:
    cur: Any = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    if cur is None:
        return default
    return str(cur)


def render_template(template: str, values: Dict[str, Any]) -> str:
    flat = {
        "machine_id": lookup(values, "machine_id"),
        "locale": lookup(values, "host.locale", "en_CA.UTF-8"),
        "keyboard": lookup(values, "host.keyboard", "us"),
        "timezone": lookup(values, "host.timezone", "America/Montreal"),
        "username": lookup(values, "default_user.username", "user"),
        "full_name": lookup(values, "default_user.full_name", "TripleBoot User"),
        "password_hash": lookup(values, "default_user.password_hash", "$6$REPLACE_WITH_SHA512_CRYPT_HASH"),
        "windows_full_name": lookup(values, "default_user.full_name", "TripleBoot User"),
        "windows_username": lookup(values, "default_user.username", "user"),
        "windows_product_key": lookup(values, "installers.windows.product_key", ""),
        "ubuntu_iso": lookup(values, "ventoy.auto_install.ubuntu_iso_pattern", "/ISO/Ubuntu/ubuntu-26.04-desktop-amd64.iso"),
        "windows_iso": lookup(values, "ventoy.auto_install.windows_iso_pattern", "/ISO/Windows/Windows11.iso"),
    }

    def replace(match: re.Match[str]) -> str:
        key = match.group(1).strip()
        return flat.get(key, "")

    return re.sub(r"\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}", replace, template)


def validate_profile(profile: Dict[str, Any]) -> list[str]:
    errors: list[str] = []
    required = [
        "machine_id",
        "host.firmware",
        "host.architecture",
        "usb.engine",
        "target_disks.ubuntu_disk.by_id",
        "target_disks.winmac_disk.by_id",
        "installers.ubuntu.version",
        "installers.windows.version",
    ]
    for field in required:
        value = lookup(profile, field)
        if not value:
            errors.append(f"missing required field: {field}")

    for disk_key in ("target_disks.ubuntu_disk.by_id", "target_disks.winmac_disk.by_id"):
        value = lookup(profile, disk_key)
        if value.startswith("REPLACE_WITH_"):
            errors.append(f"placeholder must be replaced before autonomous destructive use: {disk_key}")

    password_hash = lookup(profile, "default_user.password_hash")
    if "REPLACE_WITH" in password_hash:
        errors.append("default_user.password_hash is still a placeholder; generate a private local override")

    return errors


def generate(profile_path: Path, output_dir: Path, repo_root: Path) -> None:
    profile = read_yaml(profile_path)

    ubuntu_template_path = repo_root / lookup(profile, "installers.ubuntu.template", "templates/ubuntu/user-data.yml")
    windows_template_path = repo_root / lookup(profile, "installers.windows.template", "templates/windows/Autounattend.xml")
    ventoy_template_path = repo_root / "templates/ventoy/ventoy.json"

    ubuntu_user_data = render_template(read_text(ubuntu_template_path), profile)
    windows_unattend = render_template(read_text(windows_template_path), profile)
    ventoy_json = render_template(read_text(ventoy_template_path), profile)

    # Validate JSON after template expansion.
    json.loads(ventoy_json)

    write_text(output_dir / "autoinstall/ubuntu/user-data.yml", ubuntu_user_data)
    write_text(output_dir / "autoinstall/ubuntu/meta-data", f"instance-id: {lookup(profile, 'machine_id')}-ubuntu\nlocal-hostname: {lookup(profile, 'machine_id')}-ubuntu\n")
    write_text(output_dir / "autoinstall/windows/Autounattend.xml", windows_unattend)
    write_text(output_dir / "ventoy/ventoy.json", ventoy_json)
    write_text(output_dir / "TripleBoot/profile.yml", read_text(profile_path))
    write_text(output_dir / "TripleBoot/README-AUTONOMOUS.txt", autonomous_readme(profile))


def autonomous_readme(profile: Dict[str, Any]) -> str:
    machine_id = lookup(profile, "machine_id", "unknown")
    return f"""TripleBoot autonomous payload

Machine profile: {machine_id}

Generated files:
- /ventoy/ventoy.json
- /autoinstall/ubuntu/user-data.yml
- /autoinstall/ubuntu/meta-data
- /autoinstall/windows/Autounattend.xml
- /TripleBoot/profile.yml

Safety notes:
- This payload does not bypass TripleBoot preflight checks.
- Destructive disk installation must still verify stable /dev/disk/by-id values.
- macOS official createinstallmedia is macOS-host-only.
- PC macOS/OpenCore remains machine-specific and is not universal.
- Golden-image restore is the only true zero-touch route for identical hardware.
"""


def cmd_validate(args: argparse.Namespace) -> int:
    profile = read_yaml(Path(args.profile))
    errors = validate_profile(profile)
    if errors:
        for error in errors:
            print(f"[WARN] {error}")
        return 2 if args.strict else 0
    print("[OK] Profile validates")
    return 0


def cmd_generate(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    output_dir = Path(args.output_dir).resolve()
    generate(Path(args.profile).resolve(), output_dir, repo_root)
    print(f"[OK] Generated autonomous payload: {output_dir}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="TripleBoot autonomous profile engine")
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate-profile")
    validate.add_argument("--profile", required=True)
    validate.add_argument("--strict", action="store_true")
    validate.set_defaults(func=cmd_validate)

    generate_cmd = sub.add_parser("generate-autonomous-payload")
    generate_cmd.add_argument("--profile", required=True)
    generate_cmd.add_argument("--output-dir", required=True)
    generate_cmd.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[1]))
    generate_cmd.set_defaults(func=cmd_generate)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except ProfileError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
