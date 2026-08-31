# Security Policy

WALI is pre-alpha. There are no supported release lines yet.

## Reporting a vulnerability

Do not open a public issue for vulnerabilities involving code execution, path traversal, signature validation, cross-process authorization, update integrity, catalog signing, or destructive data loss.

Until a private reporting address is published, contact the repository owner through a private channel associated with the hosting account. Include:

- affected commit or version;
- macOS version and hardware;
- reproduction steps or proof of concept;
- realistic impact;
- whether user interaction or special permissions are required;
- suggested mitigation, if known.

Do not include personal media, credentials, access tokens, or unrelated user data.

## Security boundaries

- WALI operates in the current user's GUI session.
- It must not patch protected system components, bypass SIP/FileVault, or install behavior into another user account without consent.
- Ordinary wallpaper operation must not require Accessibility, Screen Recording, Full Disk Access, or root.
- Login-item registration and experimental lock-screen integration must be explicit and reversible.
- IPC peers and remote catalog manifests must be authenticated before their data is trusted.
- Imported files, transcoder outputs, manifests, thumbnails, and catalog metadata are untrusted input.

## Safe research

Good-faith testing against your own WALI data and processes is welcome. Do not:

- test against media or accounts you do not own;
- disrupt another person's system;
- publish an exploit before a fix is available;
- extract or redistribute proprietary competitor assets or credentials;
- use WALI research to bypass macOS security controls.

## Automated tests

Security and compatibility tests use temporary directories and sanitized fixtures. They never mutate the user's live Apple wallpaper store or delete source media.
