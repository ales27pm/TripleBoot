# Security Policy

TripleBoot performs operations that can destroy data when explicitly requested. Treat it as an administrative tool.

## Reporting issues

Open a GitHub issue for:

- unsafe destructive behavior
- partitioning bugs
- incorrect disk detection
- broken root-disk protection
- incorrect EFI backup/restore behavior
- OpenCore scaffold generation bugs

## Out of scope

This project does not provide:

- Apple installer files
- Apple serial numbers
- DRM bypasses
- firmware unlock exploits
- BitLocker bypasses
- malware or stealth payloads

## Operational security

Before running destructive commands:

- Back up data.
- Back up EFI partitions.
- Confirm exact disk names.
- Keep recovery media available.
- Suspend BitLocker when modifying Windows boot files or boot order.
