# NTFS Access for macOS

NTFS Access is a macOS utility for using external NTFS drives in Finder with read and write access.

It installs a menu bar app, a background mount service, and a Disk Utility formatter entry named `Windows NT File System (NTFS Access)`. The dashboard groups NTFS partitions by physical drive and shows whether each partition is mounted read/write, in read-only fallback, failed, or ejected.

## Download

Download `NTFSAccess-installer.pkg` from the latest GitHub Release.

The app bundle inside the package is ad-hoc signed. The installer package is unsigned and not notarized because the project does not yet use an Apple Developer ID. macOS may show security or privacy prompts during installation.

## Requirements

- Apple Silicon Mac
- macOS 13 or newer
- macFUSE installed and approved in System Settings
- Administrator password for installation
- Full Disk Access enabled for `NTFS Access.app`

NTFS Access relies on macFUSE because macOS does not provide a public built-in way for third-party apps to mount NTFS volumes as writable filesystems. NTFS Access uses macFUSE plus a bundled `ntfs-3g` toolchain for the filesystem layer, then adds macOS integration, safety checks, a dashboard, installer support, and recovery controls.

## Install

1. Install macFUSE from [macfuse.github.io](https://macfuse.github.io) and approve it if macOS asks.
2. Download `NTFSAccess-installer.pkg` from Releases.
3. Open the package and finish the installer.
4. Open System Settings -> Privacy & Security -> Full Disk Access.
5. Enable Full Disk Access for `NTFS Access.app`.
6. Unplug and replug the NTFS drive, or click `Fix` in the NTFS Access dashboard.

## Use

- Plug in an NTFS drive and wait a few seconds.
- Click the NTFS Access menu bar icon to open the `NTFS Drives` dashboard.
- Use Finder normally when a partition is shown as read/write.
- Click `Fix` on a non-green partition after granting Full Disk Access or reconnecting a drive.
- Click `Eject` before unplugging a partition.

Disk Utility can erase a test drive or partition as `Windows NT File System (NTFS Access)`. Apple's Disk Utility may still disable live plus/minus partition controls on some NTFS disks; NTFS Access cannot force Apple's UI to offer live NTFS resizing.

## Safety

- Keep backups of important drives.
- Do not test formatting or partitioning on a drive that contains data you care about.
- If NTFS Access detects an unsafe NTFS state, such as a dirty or hibernated Windows volume, it keeps the drive read-only instead of forcing writes.
- Because this build is not Developer ID signed or notarized, reinstalling a rebuilt package can make macOS ask for privacy approval again.

## Included Tools

- Menu bar dashboard with physical-drive grouping and per-partition status
- Per-partition `Fix`, rescan, reveal, and eject controls
- Automatic NTFS scan and remount service
- Read-only fallback preservation when writable takeover is unsafe or blocked
- Disk Utility formatter bundle for `Windows NT File System (NTFS Access)`
- Bundled NTFS toolchain
- Diagnostic command-line tool at `/usr/local/bin/ntfsaccessctl`
- Installer and uninstaller

## Command-Line Checks

```bash
ntfsaccessctl doctor
ntfsaccessctl status
ntfsaccessctl list-volumes --verbose
ntfsaccessctl scan-now
```

For a non-green partition shown by `list-volumes --verbose`, use:

```bash
sudo ntfsaccessctl repair-volume /dev/diskXsY
```

Replace `/dev/diskXsY` with the partition identifier from the dashboard or CLI.

## Build From Source

Source builds require Swift Package Manager, macFUSE, and the managed NTFS toolchain:

```bash
./scripts/bootstrap_ntfs_toolchain.sh --install-build-deps
sudo ./scripts/bootstrap_ntfs_toolchain.sh
./scripts/package_pkg.sh
```

The installer is written to:

```text
dist/NTFSAccess-installer.pkg
```

## Verify A Local Build

```bash
swift test
./scripts/verify_install.sh
```

## Uninstall

```bash
sudo /Library/Application\ Support/NTFSAccess/uninstall.sh
```
