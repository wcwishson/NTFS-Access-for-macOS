# NTFS Access 1.0.2

This release adds dashboard controls for how NTFS Access starts when you log in.

## What's New

- Adds `Start with this Mac` to the NTFS Drives dashboard.
- Adds `Start minimized` to keep the dashboard hidden at login while leaving the menu bar icon available.
- When `Start minimized` is off, NTFS Access can show the dashboard automatically after login.
- Keeps manual opening simple: clicking the menu bar icon still brings the dashboard forward.

## Install Notes

1. Install and approve macFUSE first.
2. Install `NTFSAccess-installer.pkg`.
3. Enable Full Disk Access for `NTFS Access.app`.
4. Replug the NTFS drive or click `Fix` in the dashboard.

The app bundle inside the package is ad-hoc signed. The installer package is unsigned and not notarized. macOS may show security or privacy prompts.

## Known Limits

- Developer ID signing and notarization are not included yet.
- Windows-created dirty, hibernated, sparse, compressed, EFS, alternate data stream, reparse point, and junction fixtures are not covered by this release.
- 4Kn or unusual-sector hardware is not covered by this release.
- Apple Disk Utility may keep live partition plus/minus controls disabled for some NTFS disks. NTFS Access provides command-line diagnostics and recovery, but it cannot force Apple's UI to offer live NTFS resizing.

## SHA-256

`NTFSAccess-installer.pkg`

```text
5734a08a1c35667248a19d5afbe9c5bbee32b12f33a2523851b2eb2879d02a0b
```
