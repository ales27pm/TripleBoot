# Contributing

TripleBoot is a safety-first automation project. Contributions should improve reliability, documentation, validation, or hardware detection without making destructive operations easier to trigger accidentally.

## Rules

- No blind destructive actions.
- No bundled Apple files, serials, installers, or copyrighted vendor firmware.
- No claim that a generated OpenCore config is final for all hardware.
- Use clear typed confirmations for risky operations.
- Keep OpenCore generation reviewable.
- Prefer dry-run support for new disk operations.

## Testing checklist

Before opening a pull request:

```bash
bash -n scripts/tripleboot_aio.sh
shellcheck scripts/tripleboot_aio.sh
```

For partition logic, test with loopback disks before real hardware.

## Style

- Bash should use `set -Eeuo pipefail`.
- Quote variables.
- Prefer explicit failure with actionable messages.
- Use small helper functions for disk naming and root-disk protection.
