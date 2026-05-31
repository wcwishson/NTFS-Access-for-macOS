# NTFS Access 1.0.0

This is the first public release of NTFS Access for macOS.

## Highlights

- Mounts external NTFS partitions through macFUSE and a bundled `ntfs-3g` toolchain.
- Adds a menu bar dashboard for connected NTFS drives.
- Groups NTFS partitions by physical drive for clearer multi-partition drive handling.
- Shows clear per-partition states: read/write, read-only fallback, failed, and ejected.
- Adds per-partition recovery and eject actions through the dashboard and `ntfsaccessctl`.
- Adds Disk Utility erase support through `Windows NT File System (NTFS Access)`.
- Preserves native macOS read-only NTFS visibility when writable takeover is blocked by privacy approval or unsafe drive state.
- Improves Finder behavior for folder copies, package-like folders, metadata sidecars, trash/delete workflows, and PDF/image file sets.
- Improves remount and recovery handling for busy volumes, unplug/replug cycles, and multiple NTFS partitions on the same physical drive.
- Stabilizes the dashboard refresh path so row order and row size do not jump during background scans.

## Install Notes

1. Install and approve macFUSE first.
2. Install `NTFSAccess-installer.pkg`.
3. Enable Full Disk Access for `NTFS Access.app`.
4. Replug the NTFS drive or click `Fix` in the dashboard.

The app bundle inside the package is ad-hoc signed. The installer package is unsigned and not notarized. macOS may show security or privacy prompts.

## Validation

This release was validated with:

- `swift test`: 262 tests, 0 failures
- package dry-run verification with a clean expanded payload tree
- live NTFS read/write checks on a small flash drive and a 1 TB removable NVMe SSD
- Finder-style folder copy/delete, metadata/package directories, checksum/integrity checks, remount churn, multi-partition NVMe behavior, and cross-volume copies

Known packaging note: `pkgutil --payload-files` may show AppleDouble `._*` BOM entries caused by macOS provenance metadata, but the package verifier expands the payload and confirms the installed payload tree is clean.

## Known Limits

- Developer ID signing and notarization are not included yet.
- Windows-created dirty, hibernated, sparse, compressed, EFS, alternate data stream, reparse point, and junction fixtures still need external Windows-based compatibility testing.
- 4Kn or unusual-sector hardware still needs real hardware validation.
- Apple Disk Utility may keep live partition plus/minus controls disabled for some NTFS disks. NTFS Access provides command-line diagnostics and recovery, but it cannot force Apple's UI to offer live NTFS resizing.

## SHA-256

`NTFSAccess-installer.pkg`

```text
0ad4fc26e4bc3c65b80e57f008ca55265394cd20487425a069a03d3504d2fc05
```
