@testable import NTFSAccessCore
import XCTest

final class NTFSMounterTests: XCTestCase {
    func testRawDeviceReadabilityCheckDoesNotSpawnExternalDiskReader() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessCore/NTFSMounter.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("\"/bin/dd\""))
        XCTAssertTrue(source.contains("FileHandle(forReadingAtPath: candidate)"))
    }

    func testOperationNotPermittedOnDeviceNodeIsReportedAsMacOSRawDiskDenial() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fakeNTFS3G = temporaryDirectory.appendingPathComponent("ntfs-3g")
        try """
        #!/bin/bash
        echo "Error opening '$1': Operation not permitted" >&2
        echo "Failed to mount '$1': Operation not permitted" >&2
        exit 1
        """.write(to: fakeNTFS3G, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeNTFS3G.path)

        let mounter = try NTFSMounter(
            ntfs3gPath: fakeNTFS3G.path,
            configuration: MountConfiguration(mountRoot: temporaryDirectory.path)
        )
        let volume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        XCTAssertThrowsError(try mounter.mountReadOnly(volume: volume, user: ConsoleUser(uid: 501, gid: 20))) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("macOS denied raw disk access"), message)
            XCTAssertFalse(message.contains("unsafe state"), message)
        }
    }

    func testRawDiskPermissionDeniedStopsAfterFirstMountAttempt() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let ntfs3gPath = "/tmp/ntfs-3g"
        var ntfs3gCalls: [[String]] = []
        let mounter = try NTFSMounter(
            ntfs3gPath: ntfs3gPath,
            configuration: MountConfiguration(mountRoot: temporaryDirectory.path),
            commandRunner: { executable, arguments, _, _ in
                if executable == "/usr/bin/pgrep" {
                    return ShellResult(status: 1, stdout: "", stderr: "")
                }
                if executable == ntfs3gPath {
                    ntfs3gCalls.append(arguments)
                    return ShellResult(
                        status: 1,
                        stdout: "",
                        stderr: "Error opening '\(arguments[0])': Operation not permitted"
                    )
                }
                return ShellResult(status: 0, stdout: "", stderr: "")
            }
        )
        let volume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        XCTAssertThrowsError(try mounter.mountReadWrite(volume: volume, user: ConsoleUser(uid: 501, gid: 20))) { error in
            XCTAssertTrue(error.localizedDescription.contains("macOS denied raw disk access"), error.localizedDescription)
        }
        XCTAssertEqual(ntfs3gCalls.count, 1)
        XCTAssertEqual(ntfs3gCalls.first?.first, "/dev/disk4s1")
    }

    func testNativeReadOnlyMountTemporarilyDisablesNTFSAccessBundleWhenRegisteredPersonalityBlocksFallback() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let formatterBundle = temporaryDirectory.appendingPathComponent("ntfsaccess.fs")
        try FileManager.default.createDirectory(at: formatterBundle, withIntermediateDirectories: true)

        var calls: [String] = []
        var bundleExistedDuringRecoveredMount: Bool?
        let mounter = try NTFSMounter(
            ntfs3gPath: "/tmp/ntfs-3g",
            commandRunner: { executable, arguments, _, _ in
                calls.append(([executable] + arguments).joined(separator: " "))
                if executable == "/usr/sbin/diskutil",
                   arguments == ["mount", "readOnly", "/dev/disk4s1"] {
                    if calls.filter({ $0 == "/usr/sbin/diskutil mount readOnly /dev/disk4s1" }).count == 1 {
                        return ShellResult(status: 1, stdout: "", stderr: "Volume on disk4s1 failed to mount")
                    }
                    bundleExistedDuringRecoveredMount = FileManager.default.fileExists(atPath: formatterBundle.path)
                    return ShellResult(status: 0, stdout: "mounted", stderr: "")
                }
                return ShellResult(status: 0, stdout: "", stderr: "")
            },
            formatterBundlePath: formatterBundle.path
        )

        try mounter.mountNativeReadOnly(deviceIdentifier: "disk4s1")

        XCTAssertEqual(bundleExistedDuringRecoveredMount, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: formatterBundle.path))
        XCTAssertEqual(
            calls,
            [
                "/usr/sbin/diskutil mount readOnly /dev/disk4s1",
                "/usr/sbin/diskutil listFilesystems",
                "/usr/sbin/diskutil mount readOnly /dev/disk4s1",
                "/usr/sbin/diskutil listFilesystems"
            ]
        )
    }

    func testNativeReadOnlyRecoveryKeepsGoingWhenFilesystemRefreshTimesOut() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let formatterBundle = temporaryDirectory.appendingPathComponent("ntfsaccess.fs")
        try FileManager.default.createDirectory(at: formatterBundle, withIntermediateDirectories: true)

        var calls: [String] = []
        let mounter = try NTFSMounter(
            ntfs3gPath: "/tmp/ntfs-3g",
            commandRunner: { executable, arguments, _, _ in
                calls.append(([executable] + arguments).joined(separator: " "))
                if executable == "/usr/sbin/diskutil",
                   arguments == ["mount", "readOnly", "/dev/disk4s1"] {
                    let mountAttempts = calls.filter { $0 == "/usr/sbin/diskutil mount readOnly /dev/disk4s1" }.count
                    return mountAttempts == 1
                        ? ShellResult(status: 1, stdout: "", stderr: "Volume on disk4s1 failed to mount")
                        : ShellResult(status: 0, stdout: "mounted", stderr: "")
                }
                if executable == "/usr/sbin/diskutil",
                   arguments == ["listFilesystems"] {
                    throw AppError(message: "Command timed out: /usr/sbin/diskutil listFilesystems")
                }
                return ShellResult(status: 0, stdout: "", stderr: "")
            },
            formatterBundlePath: formatterBundle.path
        )

        try mounter.mountNativeReadOnly(deviceIdentifier: "disk4s1")

        XCTAssertTrue(FileManager.default.fileExists(atPath: formatterBundle.path))
        XCTAssertEqual(
            calls,
            [
                "/usr/sbin/diskutil mount readOnly /dev/disk4s1",
                "/usr/sbin/diskutil listFilesystems",
                "/usr/sbin/diskutil mount readOnly /dev/disk4s1",
                "/usr/sbin/diskutil listFilesystems"
            ]
        )
    }

    func testNativeReadOnlyRecoveryRestoresNTFSAccessBundleWhenAppleMountStillFails() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let formatterBundle = temporaryDirectory.appendingPathComponent("ntfsaccess.fs")
        try FileManager.default.createDirectory(at: formatterBundle, withIntermediateDirectories: true)

        let mounter = try NTFSMounter(
            ntfs3gPath: "/tmp/ntfs-3g",
            commandRunner: { executable, arguments, _, _ in
                if executable == "/usr/sbin/diskutil",
                   arguments == ["mount", "readOnly", "/dev/disk4s1"] {
                    return ShellResult(status: 1, stdout: "", stderr: "Volume on disk4s1 failed to mount")
                }
                return ShellResult(status: 0, stdout: "", stderr: "")
            },
            formatterBundlePath: formatterBundle.path
        )

        XCTAssertThrowsError(try mounter.mountNativeReadOnly(deviceIdentifier: "disk4s1")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Native read-only recovery failed"), error.localizedDescription)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: formatterBundle.path))
    }

    func testNativeReadOnlyRecoveryRefusesToDeletePreexistingDisabledBundlePath() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let formatterBundle = temporaryDirectory.appendingPathComponent("ntfsaccess.fs")
        let disabledBundle = temporaryDirectory.appendingPathComponent("ntfsaccess.fs.disabled-for-native-recovery")
        try FileManager.default.createDirectory(at: formatterBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabledBundle, withIntermediateDirectories: true)
        try "sentinel".write(to: disabledBundle.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        let mounter = try NTFSMounter(
            ntfs3gPath: "/tmp/ntfs-3g",
            commandRunner: { executable, arguments, _, _ in
                if executable == "/usr/sbin/diskutil",
                   arguments == ["mount", "readOnly", "/dev/disk4s1"] {
                    return ShellResult(status: 1, stdout: "", stderr: "Volume on disk4s1 failed to mount")
                }
                return ShellResult(status: 0, stdout: "", stderr: "")
            },
            formatterBundlePath: formatterBundle.path
        )

        XCTAssertThrowsError(try mounter.mountNativeReadOnly(deviceIdentifier: "disk4s1")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Refusing to delete it"), error.localizedDescription)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: formatterBundle.path))
        XCTAssertEqual(
            try String(contentsOf: disabledBundle.appendingPathComponent("keep.txt"), encoding: .utf8),
            "sentinel"
        )
    }

    func testRestoreDisabledFormatterBundleIfNeededRepairsCrashLeftoverOnStartup() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let formatterBundle = temporaryDirectory.appendingPathComponent("ntfsaccess.fs")
        let disabledBundle = temporaryDirectory.appendingPathComponent("ntfsaccess.fs.disabled-for-native-recovery")
        try FileManager.default.createDirectory(at: disabledBundle, withIntermediateDirectories: true)
        var calls: [String] = []

        NTFSMounter.restoreDisabledFormatterBundleIfNeeded(
            formatterBundlePath: formatterBundle.path,
            commandRunner: { executable, arguments, _, _ in
                calls.append(([executable] + arguments).joined(separator: " "))
                return ShellResult(status: 0, stdout: "", stderr: "")
            }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: formatterBundle.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disabledBundle.path))
        XCTAssertEqual(calls, ["/usr/sbin/diskutil listFilesystems"])
    }

    func testUnmountUsesDirectUmountBeforeDiskutilForManagedMountPoint() throws {
        var calls: [String] = []
        let mounter = try NTFSMounter(
            ntfs3gPath: "/tmp/ntfs-3g",
            commandRunner: { executable, arguments, _, _ in
                calls.append(([executable] + arguments).joined(separator: " "))
                if executable == "/usr/bin/pgrep" {
                    return ShellResult(status: 0, stdout: "111\n222\n", stderr: "")
                }
                if executable == "/bin/kill", arguments == ["-0", "111"] {
                    return ShellResult(status: 1, stdout: "", stderr: "")
                }
                if executable == "/bin/kill", arguments == ["-0", "222"] {
                    return ShellResult(status: 0, stdout: "", stderr: "")
                }
                return ShellResult(status: 0, stdout: "", stderr: "")
            }
        )

        try mounter.unmount(deviceIdentifier: "disk4s1", mountPoint: "/Volumes/NTFSAccess-disk4s1", force: true)

        XCTAssertEqual(
            calls,
            [
                "/sbin/umount -f /Volumes/NTFSAccess-disk4s1",
                "/usr/bin/pgrep -f ntfs-3g .*/dev/(r?disk4s1)( |$).*/Volumes/NTFSAccess\\-disk4s1( |$)",
                "/bin/kill -TERM 111 222",
                "/bin/kill -0 111",
                "/bin/kill -0 222",
                "/bin/kill -KILL 222"
            ]
        )
    }

    func testUnmountFallsBackToDiskutilWhenDirectUmountFails() throws {
        var calls: [String] = []
        let mounter = try NTFSMounter(
            ntfs3gPath: "/tmp/ntfs-3g",
            commandRunner: { executable, arguments, _, _ in
                calls.append(([executable] + arguments).joined(separator: " "))
                if executable == "/sbin/umount" {
                    return ShellResult(status: 1, stdout: "", stderr: "resource busy")
                }
                return ShellResult(status: 0, stdout: "", stderr: "")
            }
        )

        try mounter.unmount(deviceIdentifier: "disk4s1", mountPoint: "/Volumes/NTFSAccess-disk4s1", force: true)

        XCTAssertEqual(calls.prefix(2), [
            "/sbin/umount -f /Volumes/NTFSAccess-disk4s1",
            "/usr/sbin/diskutil unmount force /dev/disk4s1"
        ])
    }

    func testUnmountReapsStaleWorkerAndRetriesWhenDiskutilReportsResourceBusy() throws {
        var calls: [String] = []
        var diskutilAttempts = 0
        let mounter = try NTFSMounter(
            ntfs3gPath: "/tmp/ntfs-3g",
            commandRunner: { executable, arguments, _, _ in
                calls.append(([executable] + arguments).joined(separator: " "))
                if executable == "/sbin/umount" {
                    return ShellResult(status: 1, stdout: "", stderr: "Resource busy")
                }
                if executable == "/usr/sbin/diskutil" {
                    diskutilAttempts += 1
                    if diskutilAttempts == 1 {
                        return ShellResult(status: 1, stdout: "", stderr: "Volume failed to unmount because it is busy")
                    }
                    return ShellResult(status: 0, stdout: "Unmount successful", stderr: "")
                }
                if executable == "/usr/bin/pgrep" {
                    return ShellResult(status: 0, stdout: "444\n", stderr: "")
                }
                if executable == "/bin/kill", arguments == ["-0", "444"] {
                    return ShellResult(status: 1, stdout: "", stderr: "")
                }
                return ShellResult(status: 0, stdout: "", stderr: "")
            }
        )

        try mounter.unmount(deviceIdentifier: "disk4s1", mountPoint: "/Volumes/NTFSAccess-disk4s1", force: true)

        XCTAssertEqual(
            calls,
            [
                "/sbin/umount -f /Volumes/NTFSAccess-disk4s1",
                "/usr/sbin/diskutil unmount force /dev/disk4s1",
                "/usr/bin/pgrep -f ntfs-3g .*/dev/(r?disk4s1)( |$).*/Volumes/NTFSAccess\\-disk4s1( |$)",
                "/bin/kill -TERM 444",
                "/bin/kill -0 444",
                "/sbin/umount -f /Volumes/NTFSAccess-disk4s1",
                "/usr/sbin/diskutil unmount force /dev/disk4s1",
                "/usr/bin/pgrep -f ntfs-3g .*/dev/(r?disk4s1)( |$).*/Volumes/NTFSAccess\\-disk4s1( |$)",
                "/bin/kill -TERM 444",
                "/bin/kill -0 444"
            ]
        )
    }

    func testUnmountTreatsAlreadyUnmountedMountPointAsRecoveredAndReapsStaleWorker() throws {
        var calls: [String] = []
        let mounter = try NTFSMounter(
            ntfs3gPath: "/tmp/ntfs-3g",
            commandRunner: { executable, arguments, _, _ in
                calls.append(([executable] + arguments).joined(separator: " "))
                if executable == "/sbin/umount" {
                    return ShellResult(status: 1, stdout: "", stderr: "not currently mounted")
                }
                if executable == "/usr/bin/pgrep" {
                    return ShellResult(status: 0, stdout: "111\n", stderr: "")
                }
                if executable == "/bin/kill", arguments == ["-0", "111"] {
                    return ShellResult(status: 1, stdout: "", stderr: "")
                }
                return ShellResult(status: 0, stdout: "", stderr: "")
            }
        )

        try mounter.unmount(deviceIdentifier: "disk4s1", mountPoint: "/Volumes/NTFSAccess-disk4s1", force: true)

        XCTAssertEqual(
            calls,
            [
                "/sbin/umount -f /Volumes/NTFSAccess-disk4s1",
                "/usr/bin/pgrep -f ntfs-3g .*/dev/(r?disk4s1)( |$).*/Volumes/NTFSAccess\\-disk4s1( |$)",
                "/bin/kill -TERM 111",
                "/bin/kill -0 111"
            ]
        )
        XCTAssertFalse(calls.contains("/usr/sbin/diskutil unmount force /dev/disk4s1"))
    }

    func testMountReadWriteCleansStaleNTFS3GWorkersBeforeStartingNewMount() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var calls: [String] = []
        let mounter = try NTFSMounter(
            ntfs3gPath: "/tmp/ntfs-3g",
            configuration: MountConfiguration(mountRoot: temporaryDirectory.path),
            commandRunner: { executable, arguments, _, _ in
                calls.append(([executable] + arguments).joined(separator: " "))
                if executable == "/usr/bin/pgrep" {
                    return ShellResult(status: 0, stdout: "333\n", stderr: "")
                }
                if executable == "/bin/kill", arguments == ["-0", "333"] {
                    return ShellResult(status: 1, stdout: "", stderr: "")
                }
                return ShellResult(status: 0, stdout: "", stderr: "")
            }
        )

        let volume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        _ = try mounter.mountReadWrite(volume: volume, user: ConsoleUser(uid: 501, gid: 20))

        XCTAssertGreaterThanOrEqual(calls.count, 2)
        XCTAssertTrue(calls[0].hasPrefix("/usr/bin/pgrep -f ntfs-3g .*/dev/(r?disk4s1)( |$).*"), calls[0])
        XCTAssertTrue(calls[0].contains("NTFSAccess\\-disk4s1( |$)"), calls[0])
        XCTAssertEqual(calls[1], "/bin/kill -TERM 333")
        XCTAssertTrue(calls.contains("/bin/kill -0 333"))
        XCTAssertFalse(calls.contains { $0.contains("-KILL 333") })
        XCTAssertTrue(calls.contains { $0.contains("/tmp/ntfs-3g /dev/disk4s1") })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsaccess-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
