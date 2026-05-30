# Autonomous Profile Engine

TripleBoot uses a profile engine to keep zero-touch install logic from becoming scattered across Bash commands.

The profile is the source of truth for:

- target machine identity
- firmware requirements
- target disk identities
- wipe policy
- Ubuntu unattended installation
- Windows unattended installation
- Ventoy auto-install mapping
- macOS/OpenCore/OSX-KVM strategy

## Commands

```bash
python3 scripts/tripleboot_profile_engine.py validate-profile \
  --profile profiles/pc-27pm.yml

python3 scripts/tripleboot_profile_engine.py generate-autonomous-payload \
  --profile profiles/pc-27pm.yml \
  --output-dir /tmp/tripleboot-autonomous
```

The generated output contains:

```text
autoinstall/ubuntu/user-data.yml
autoinstall/ubuntu/meta-data
autoinstall/windows/Autounattend.xml
ventoy/ventoy.json
TripleBoot/profile.yml
TripleBoot/README-AUTONOMOUS.txt
```

## Safety model

The generator is intentionally read-only. It does not partition disks, wipe USB drives, install bootloaders, or modify EFI entries.

The Bash AIO script remains responsible for:

- destructive confirmations
- root disk protection
- DATA partition protection
- USB formatting
- Ventoy installation
- staging generated files to the USB

## macOS limitation

The profile engine does not claim universal macOS automation. macOS has three supported lanes:

1. Official createinstallmedia flow from macOS.
2. PC/OpenCore flow using a machine-specific EFI and user-supplied Apple binaries.
3. OSX-KVM VM flow using BaseSystem/OpenCore VM assets.

True zero-touch for macOS on PC hardware is only realistic in golden-image restore mode for one exact hardware profile.
