import XCTest

final class FilesystemBundleScriptTests: XCTestCase {
    func testFilesystemBundleProbeOrderPreemptsAppleNativeNTFSMountingForNTFSLeaves() throws {
        let infoPlist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packaging/Filesystems/ntfsaccess.fs/Contents/Info.plist")
        let data = try Data(contentsOf: infoPlist)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let mediaTypes = plist["FSMediaTypes"] as? [String: Any] else {
            return XCTFail("Unable to read filesystem bundle media types")
        }

        for mediaType in ["Windows_NTFS", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"] {
            guard let entry = mediaTypes[mediaType] as? [String: Any],
                  let probeOrder = entry["FSProbeOrder"] as? Int else {
                return XCTFail("Missing FSProbeOrder for \(mediaType)")
            }
            XCTAssertGreaterThan(
                1_000,
                probeOrder,
                "NTFS Access must probe before Apple's built-in read-only NTFS personality so Finder automounts can become writable."
            )
        }

        guard let partitionless = mediaTypes["Partitionless"] as? [String: Any],
              let partitionlessProbeOrder = partitionless["FSProbeOrder"] as? Int else {
            return XCTFail("Missing FSProbeOrder for Partitionless")
        }
        XCTAssertGreaterThan(
            partitionlessProbeOrder,
            3_000,
            "Partitionless probing should remain behind Apple's broad fallback to avoid claiming whole devices too aggressively."
        )
    }

    func testUtilMountActionForwardsDeviceMountpointAndFlagsThroughThinWrapper() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let utilSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packaging/Filesystems/ntfsaccess.fs/Contents/Resources/ntfsaccess.util")
        let utilCopy = temporaryDirectory.appendingPathComponent("ntfsaccess.util")
        try FileManager.default.copyItem(at: utilSource, to: utilCopy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: utilCopy.path)

        let recorder = temporaryDirectory.appendingPathComponent("mount_ntfsaccess")
        let output = temporaryDirectory.appendingPathComponent("args.txt")
        try """
        #!/bin/bash
        printf '%s\n' "$@" > "\(output.path)"
        exit 0
        """.write(to: recorder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)

        let result = try run(
            utilCopy.path,
            ["-m", "disk4s1", "/Volumes/Passport", "removable", "writable", "nosuid", "nodev"]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        let forwardedArguments = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            forwardedArguments,
            ["/dev/disk4s1", "/Volumes/Passport", "removable", "writable", "nosuid", "nodev"]
        )
    }

    func testMountWrapperDelegatesThroughInstalledAppHelperIdentity() throws {
        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packaging/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess")
        let source = try String(contentsOf: wrapper, encoding: .utf8)

        XCTAssertTrue(source.contains("/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp"))
        XCTAssertTrue(source.contains("--mount-helper"))
        XCTAssertTrue(source.contains("exec \"$APP_HELPER\" --mount-helper \"$@\""))
    }

    func testFilesystemUtilDoesNotTrustEnvironmentOrPathByDefaultForPrivilegedTools() throws {
        let util = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packaging/Filesystems/ntfsaccess.fs/Contents/Resources/ntfsaccess.util")
        let source = try String(contentsOf: util, encoding: .utf8)

        XCTAssertTrue(source.contains("NTFSACCESS_ALLOW_UNSAFE_TOOLCHAIN_LOOKUP"))
        XCTAssertTrue(source.contains("trusted_executable"))
        XCTAssertTrue(source.contains("stat -f '%u'"))
        XCTAssertTrue(source.contains("stat -f '%Lp'"))
        XCTAssertFalse(source.contains("command -v \"$binary\" 2>/dev/null)\"; then"))
        XCTAssertFalse(source.contains("/opt/homebrew/bin/$binary"))
        XCTAssertFalse(source.contains("/usr/local/bin/$binary"))
        XCTAssertLessThan(
            try XCTUnwrap(source.range(of: "\"/Applications/NTFS Access.app/Contents/Library/NTFSAccess/toolchain/bin/$binary\"")?.lowerBound),
            try XCTUnwrap(source.range(of: "NTFSACCESS_TOOLCHAIN_BIN")?.lowerBound)
        )
    }

    func testPreinstallChecksTrustedMacFUSEInsteadOfEnvironmentOrPath() throws {
        let preinstall = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packaging/Scripts/preinstall")
        let source = try String(contentsOf: preinstall, encoding: .utf8)

        XCTAssertTrue(source.contains("trusted_executable"))
        XCTAssertTrue(source.contains("/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse"))
        XCTAssertFalse(source.contains("NTFSACCESS_TOOLCHAIN_BIN"))
        XCTAssertFalse(source.contains("NTFSACCESS_TOOLCHAIN_ROOT"))
        XCTAssertFalse(source.contains("command -v \"$binary\""))
        XCTAssertFalse(source.contains("command -v mount_macfuse"))
        XCTAssertFalse(source.contains("/opt/homebrew/bin/$binary"))
        XCTAssertFalse(source.contains("/usr/local/bin/$binary"))
    }

    func testPreinstallDoesNotBlockPackageSuppliedToolchainBeforePayloadInstall() throws {
        let preinstall = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packaging/Scripts/preinstall")
        let source = try String(contentsOf: preinstall, encoding: .utf8)

        XCTAssertFalse(source.contains("have_ntfs3g"))
        XCTAssertFalse(source.contains("have_mkntfs"))
        XCTAssertFalse(source.contains("have_ntfsfix"))
        XCTAssertFalse(source.contains("Install macFUSE and the managed NTFS toolchain, then rerun installer."))
        XCTAssertTrue(source.contains("This package installs the managed NTFS toolchain"))
        XCTAssertTrue(source.contains("trusted_executable /Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsaccess-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
