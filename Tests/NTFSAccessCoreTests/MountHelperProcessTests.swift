@testable import NTFSMountDaemonCore
@testable import NTFSAccessCore
import XCTest

extension LockedStatus: @unchecked Sendable {}

final class MountHelperProcessTests: XCTestCase {
    func testNormalizesDiskIdentifier() {
        XCTAssertEqual(MountHelperProcess.normalizeDevice("disk4s1"), "/dev/disk4s1")
        XCTAssertEqual(MountHelperProcess.normalizeDevice("/dev/disk4s1"), "/dev/disk4s1")
    }

    func testRecognizesReadOnlyFlagsFromDiskArbitration() {
        XCTAssertTrue(MountHelperProcess.readOnlyRequested(in: ["removable", "readonly", "nosuid"]))
        XCTAssertTrue(MountHelperProcess.readOnlyRequested(in: ["rdonly"]))
        XCTAssertTrue(MountHelperProcess.readOnlyRequested(in: ["ro"]))
        XCTAssertFalse(MountHelperProcess.readOnlyRequested(in: ["removable", "writable", "nosuid"]))
    }

    func testMountOptionsUseDeferredWritablePermissionsAndConsoleOwnedReadOnlyFallback() {
        let user = ConsoleUser(uid: 501, gid: 20)

        XCTAssertEqual(
            MountHelperProcess.mountOptions(user: user, readOnly: false, volumeName: "My Drive"),
            [
                "allow_other",
                "defer_permissions",
                "volname=My_Drive",
                "local",
                "auto_xattr",
                "auto_cache",
                "big_writes",
                "noatime",
                "nosyncwrites",
                "nosynconclose",
                "iosize=1048576",
                "daemon_timeout=60"
            ]
        )
        XCTAssertEqual(
            MountHelperProcess.mountOptions(user: user, readOnly: true, volumeName: "My Drive"),
            ["uid=501", "gid=20", "umask=022", "allow_other", "ro", "volname=My_Drive", "local"]
        )
    }

    func testMountHelperUsesOptionGradientForWritableAndReadOnlyMounts() {
        let user = ConsoleUser(uid: 501, gid: 20)

        XCTAssertEqual(
            MountHelperProcess.mountOptionSets(user: user, readOnly: false, volumeName: "My Drive"),
            [
                [
                    "allow_other",
                    "defer_permissions",
                    "volname=My_Drive",
                    "local",
                    "auto_xattr",
                    "auto_cache",
                    "big_writes",
                    "noatime",
                    "nosyncwrites",
                    "nosynconclose",
                    "iosize=1048576",
                    "daemon_timeout=60"
                ],
                ["allow_other", "defer_permissions", "volname=My_Drive", "local"],
                ["allow_other", "defer_permissions", "volname=My_Drive"],
                ["allow_other", "defer_permissions"]
            ]
        )
        XCTAssertEqual(
            MountHelperProcess.mountOptionSets(user: user, readOnly: true, volumeName: "My Drive"),
            [
                ["uid=501", "gid=20", "umask=022", "allow_other", "ro", "volname=My_Drive", "local"],
                ["uid=501", "gid=20", "umask=022", "allow_other", "ro", "volname=My_Drive", "local", "noatime"],
                ["uid=501", "gid=20", "umask=022", "allow_other", "ro", "volname=My_Drive"],
                ["uid=501", "gid=20", "umask=022", "allow_other", "ro"],
                ["uid=501", "gid=20", "umask=022", "ro"]
            ]
        )
    }

    func testWritableMountOptionsAllowFinderMetadataWrites() {
        let flattened = MountHelperProcess.mountOptionSets(
            user: ConsoleUser(uid: 501, gid: 20),
            readOnly: false,
            volumeName: "My Drive"
        )
        .flatMap { $0 }

        XCTAssertTrue(flattened.contains("auto_xattr"))
        XCTAssertTrue(flattened.contains("nosyncwrites"))
        XCTAssertTrue(flattened.contains("nosynconclose"))
        XCTAssertFalse(flattened.contains("noapplexattr"))
        XCTAssertFalse(flattened.contains("noappledouble"))
    }

    func testConservativeDurabilityMountHelperOptionsRemoveOnlyNoSyncWrites() {
        let firstOptions = MountHelperProcess.mountOptionSets(
            user: ConsoleUser(uid: 501, gid: 20),
            readOnly: false,
            volumeName: "My Drive",
            durabilityMode: .conservative
        )[0]

        XCTAssertTrue(firstOptions.contains("allow_other"))
        XCTAssertTrue(firstOptions.contains("defer_permissions"))
        XCTAssertTrue(firstOptions.contains("volname=My_Drive"))
        XCTAssertTrue(firstOptions.contains("local"))
        XCTAssertTrue(firstOptions.contains("auto_xattr"))
        XCTAssertTrue(firstOptions.contains("auto_cache"))
        XCTAssertTrue(firstOptions.contains("big_writes"))
        XCTAssertTrue(firstOptions.contains("noatime"))
        XCTAssertTrue(firstOptions.contains("iosize=1048576"))
        XCTAssertTrue(firstOptions.contains("daemon_timeout=60"))
        XCTAssertFalse(firstOptions.contains("nosyncwrites"))
        XCTAssertFalse(firstOptions.contains("nosynconclose"))
    }

    func testWritableMountOptionsDeferMacFUSEPermissionChecks() {
        let optionSets = MountHelperProcess.mountOptionSets(
            user: ConsoleUser(uid: 501, gid: 20),
            readOnly: false,
            volumeName: "My Drive"
        )

        XCTAssertFalse(optionSets.isEmpty)
        for options in optionSets {
            XCTAssertTrue(options.contains("allow_other"), options.joined(separator: ","))
            XCTAssertTrue(options.contains("defer_permissions"), options.joined(separator: ","))
            XCTAssertFalse(options.contains("default_permissions"), options.joined(separator: ","))
            XCTAssertFalse(options.contains("uid=501"), options.joined(separator: ","))
            XCTAssertFalse(options.contains("gid=20"), options.joined(separator: ","))
            XCTAssertFalse(options.contains("umask=022"), options.joined(separator: ","))
        }
    }

    func testWritableMountOptionsAvoidNTFS3GDefaultPermissionsTriggersWhenDeferringMacFUSEPermissions() {
        let optionSets = MountHelperProcess.mountOptionSets(
            user: ConsoleUser(uid: 501, gid: 20),
            readOnly: false,
            volumeName: "My Drive"
        )

        for options in optionSets {
            XCTAssertTrue(options.contains("defer_permissions"), options.joined(separator: ","))
            XCTAssertFalse(options.contains { $0.hasPrefix("uid=") }, options.joined(separator: ","))
            XCTAssertFalse(options.contains { $0.hasPrefix("gid=") }, options.joined(separator: ","))
            XCTAssertFalse(options.contains { $0.hasPrefix("umask=") }, options.joined(separator: ","))
            XCTAssertFalse(options.contains { $0.hasPrefix("fmask=") }, options.joined(separator: ","))
            XCTAssertFalse(options.contains { $0.hasPrefix("dmask=") }, options.joined(separator: ","))
            XCTAssertFalse(options.contains("permissions"), options.joined(separator: ","))
            XCTAssertFalse(options.contains("acl"), options.joined(separator: ","))
        }
    }

    func testMountHelperRepairsExistingRootOnlyMountPointBeforeMounting() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let mountPoint = temporaryDirectory.appendingPathComponent("Mount")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mountPoint.path)

        try MountHelperProcess.prepareMountPoint(mountPoint.path)

        let attributes = try FileManager.default.attributesOfItem(atPath: mountPoint.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o755)
    }

    func testExtractsVolumeNameFromDiskArbitrationFlags() {
        XCTAssertEqual(
            MountHelperProcess.volumeName(from: ["removable", "volname=HP NTFS A", "nosuid"]),
            "HP NTFS A"
        )
        XCTAssertNil(MountHelperProcess.volumeName(from: ["removable", "writable"]))
    }

    func testDerivesVolumeNameFromDiskutilInfoWhenDiskArbitrationDoesNotPassIt() {
        let plist = """
        noise before plist
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>VolumeName</key>
            <string>HP NTFS A</string>
        </dict>
        </plist>
        """

        let name = MountHelperProcess.derivedVolumeName(for: "/dev/disk13s2") { executable, arguments, _, timeout in
            XCTAssertEqual(executable, "/usr/sbin/diskutil")
            XCTAssertEqual(arguments, ["info", "-plist", "/dev/disk13s2"])
            XCTAssertEqual(timeout, 8)
            return ShellResult(status: 0, stdout: plist, stderr: "")
        }

        XCTAssertEqual(name, "HP NTFS A")
    }

    func testDeviceCandidatesPreferBlockDiskWhenRawDiskIsPresent() {
        let candidates = MountHelperProcess.deviceCandidates(for: "/dev/disk4s1") { path in
            path == "/dev/rdisk4s1"
        }

        XCTAssertEqual(candidates, ["/dev/disk4s1", "/dev/rdisk4s1"])
    }

    func testWritableRawDiskPermissionDeniedDoesNotFallbackToReadOnly() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fakeNTFS3G = temporaryDirectory.appendingPathComponent("ntfs-3g")
        let attemptsLog = temporaryDirectory.appendingPathComponent("attempts.log")
        try """
        #!/bin/bash
        echo "$1|$4" >> "\(attemptsLog.path)"
        echo "Error opening '$1': Permission denied" >&2
        exit 1
        """.write(to: fakeNTFS3G, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeNTFS3G.path)

        let status = MountHelperProcess.runResolved(
            ntfs3gPath: fakeNTFS3G.path,
            device: "/dev/disk4s1",
            mountPoint: temporaryDirectory.appendingPathComponent("Mount").path,
            flags: ["writable"],
            requestedVolumeName: "Passport",
            user: ConsoleUser(uid: 501, gid: 20),
            fileExists: { $0 == "/dev/rdisk4s1" }
        )

        XCTAssertEqual(status, MountHelperProcess.rawDiskPermissionDeniedStatus)
        let attempts = try String(contentsOf: attemptsLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertTrue(attempts[0].hasPrefix("/dev/disk4s1|"), attempts[0])
        XCTAssertFalse(attempts[0].contains(",ro"), attempts[0])
    }

    func testMountHelperDrainsVerboseNTFS3GOutputWhileProcessRuns() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fakeNTFS3G = temporaryDirectory.appendingPathComponent("ntfs-3g")
        let pidFile = temporaryDirectory.appendingPathComponent("ntfs-3g.pid")
        try """
        #!/bin/bash
        echo "$$" > "\(pidFile.path)"
        /usr/bin/perl -e 'print "O" x (128 * 1024); print STDERR "E" x (128 * 1024);'
        exit 0
        """.write(to: fakeNTFS3G, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeNTFS3G.path)

        let group = DispatchGroup()
        let statusBox = LockedStatus()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MountHelperProcess.runResolved(
                ntfs3gPath: fakeNTFS3G.path,
                device: "/dev/disk4s1",
                mountPoint: temporaryDirectory.appendingPathComponent("Mount").path,
                flags: ["writable"],
                requestedVolumeName: "Verbose",
                user: ConsoleUser(uid: 501, gid: 20),
                fileExists: { _ in false }
            )
            statusBox.set(result)
            group.leave()
        }

        if group.wait(timeout: .now() + 3) == .timedOut {
            killRecordedProcess(pidFile: pidFile)
            _ = group.wait(timeout: .now() + 1)
            XCTFail("mount helper hung while ntfs-3g produced verbose stdout/stderr")
            return
        }

        XCTAssertEqual(statusBox.value, 0)
    }

    func testMountHelperTimesOutHungNTFS3GAndDoesNotFallbackToReadOnly() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fakeNTFS3G = temporaryDirectory.appendingPathComponent("ntfs-3g")
        let attemptsLog = temporaryDirectory.appendingPathComponent("attempts.log")
        let pidFile = temporaryDirectory.appendingPathComponent("ntfs-3g.pid")
        try """
        #!/bin/bash
        echo "$$" > "\(pidFile.path)"
        echo "$1|$4" >> "\(attemptsLog.path)"
        trap '' TERM
        /bin/sleep 20
        """.write(to: fakeNTFS3G, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeNTFS3G.path)

        let start = Date()
        let status = MountHelperProcess.runResolved(
            ntfs3gPath: fakeNTFS3G.path,
            device: "/dev/disk4s1",
            mountPoint: temporaryDirectory.appendingPathComponent("Mount").path,
            flags: ["writable"],
            requestedVolumeName: "Hung",
            user: ConsoleUser(uid: 501, gid: 20),
            mountAttemptTimeout: 1.0,
            fileExists: { _ in false }
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(status, MountHelperProcess.mountAttemptTimeoutStatus)
        XCTAssertLessThan(elapsed, 3)
        let attempts = try String(contentsOf: attemptsLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertFalse(attempts[0].contains(",ro"), attempts[0])

        let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertNotEqual(kill(pid, 0), 0, "timed-out ntfs-3g process should be killed")
    }

    func testBundledToolPathResolvesInsideAppBundle() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let executable = temporaryDirectory
            .appendingPathComponent("NTFS Access.app/Contents/MacOS/NTFSMenuApp")
        let tool = temporaryDirectory
            .appendingPathComponent("NTFS Access.app/Contents/Library/NTFSAccess/toolchain/bin/ntfs-3g")

        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: tool.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        FileManager.default.createFile(atPath: tool.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        XCTAssertEqual(
            MountHelperProcess.bundledToolPath(named: "ntfs-3g", appExecutablePath: executable.path),
            tool.path
        )
    }

    func testResolveToolPathFallsBackToManagedLibraryToolchainForFilesystemHelper() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let executable = temporaryDirectory
            .appendingPathComponent("mount_ntfsaccess")
        let managedTool = URL(fileURLWithPath: NTFSAccessPaths.managedToolchainBinPath)
            .appendingPathComponent("ntfs-3g")

        let fileManager = StubExecutableFileManager(executablePaths: [managedTool.path])

        XCTAssertEqual(
            MountHelperProcess.resolveToolPath(
                named: "ntfs-3g",
                appExecutablePath: executable.path,
                fileManager: fileManager
            ),
            managedTool.path
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsaccess-helper-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func killRecordedProcess(pidFile: URL) {
        guard let rawPID = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        kill(pid, SIGKILL)
    }
}

private final class StubExecutableFileManager: FileManager {
    private let executablePaths: Set<String>

    init(executablePaths: Set<String>) {
        self.executablePaths = executablePaths
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private final class LockedStatus {
    private let lock = NSLock()
    private var storedValue: Int32?

    var value: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Int32) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
