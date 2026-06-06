@testable import NTFSAccessCore
import XCTest

final class DependencyCheckerTests: XCTestCase {
    func testDefaultToolSearchPrefersAppBundledToolchainBeforeLibraryToolchain() {
        let directories = DependencyChecker.toolSearchDirectories(environment: [:])

        XCTAssertLessThan(
            try XCTUnwrap(directories.firstIndex(of: NTFSAccessPaths.appBundledToolchainBinPath)),
            try XCTUnwrap(directories.firstIndex(of: NTFSAccessPaths.managedToolchainBinPath))
        )
        XCTAssertLessThan(
            try XCTUnwrap(directories.firstIndex(of: NTFSAccessPaths.appBundledToolchainSbinPath)),
            try XCTUnwrap(directories.firstIndex(of: NTFSAccessPaths.managedToolchainSbinPath))
        )
    }

    func testPrivilegedToolSearchIgnoresEnvironmentOverridesByDefault() {
        let directories = DependencyChecker.toolSearchDirectories(
            environment: [
                "NTFSACCESS_TOOLCHAIN_BIN": "/tmp/evil-bin",
                "NTFSACCESS_TOOLCHAIN_ROOT": "/tmp/evil-root"
            ],
            allowUnsafeOverrides: false
        )

        XCTAssertFalse(directories.contains("/tmp/evil-bin"))
        XCTAssertFalse(directories.contains("/tmp/evil-root/bin"))
        XCTAssertFalse(directories.contains("/tmp/evil-root/sbin"))
        XCTAssertEqual(directories.first, NTFSAccessPaths.appBundledToolchainBinPath)
    }

    func testToolSearchUsesEnvironmentOverridesOnlyWithExplicitUnsafeFlag() {
        let directories = DependencyChecker.toolSearchDirectories(
            environment: [
                "NTFSACCESS_ALLOW_UNSAFE_TOOLCHAIN_LOOKUP": "1",
                "NTFSACCESS_TOOLCHAIN_BIN": "/tmp/dev-bin",
                "NTFSACCESS_TOOLCHAIN_ROOT": "/tmp/dev-root"
            ]
        )

        XCTAssertEqual(directories.prefix(3), ["/tmp/dev-bin", "/tmp/dev-root/bin", "/tmp/dev-root/sbin"])
    }

    func testPrivilegedResolverRejectsUserWritableToolPathWithDiagnostic() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let tool = temporaryDirectory.appendingPathComponent("ntfs-3g")
        FileManager.default.createFile(atPath: tool.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let resolution = DependencyChecker.resolveBinaryDetailed(
            named: "ntfs-3g",
            includePATHLookup: false,
            fallbackDirectories: [temporaryDirectory.path],
            environment: [:],
            privilegedRuntime: true
        )

        XCTAssertNotEqual(resolution.path, tool.path)
        XCTAssertTrue(resolution.rejectionMessages.contains { message in
            message.contains("Rejected ntfs-3g")
                && (message.contains("owner uid") || message.contains("directory"))
        }, resolution.rejectionMessages.joined(separator: "\n"))
    }

    func testPrivilegedResolverRejectsNTFSToolWithoutTrustedCompanionLibrary() {
        if FileManager.default.fileExists(atPath: "/usr/bin/true") {
            let rejection = DependencyChecker.trustedToolPathRejectionReason(
                "/usr/bin/true",
                validateCompanionLibrary: true
            )

            XCTAssertNotNil(rejection)
            XCTAssertTrue(rejection?.contains("companion library") == true, rejection ?? "")
            XCTAssertTrue(rejection?.contains("libntfs-3g.89.dylib") == true, rejection ?? "")
        }
    }

    func testInstalledMacFUSEHelperWithUnloadedKernelExtensionIsAdvisory() {
        let report = dependencyReport(macFUSEKernelLoaded: { false })

        XCTAssertFalse(
            report.mountIssues.contains { $0.localizedCaseInsensitiveContains("macFUSE kernel extension not loaded") }
        )
        XCTAssertTrue(
            report.advisoryNotes.contains { $0.localizedCaseInsensitiveContains("macFUSE kernel extension not loaded") }
        )
    }

    func testEmptyArchitectureProbeFallsBackWithoutBlockingMountReadiness() {
        let report = dependencyReport(architectureProvider: { "" })

        XCTAssertFalse(report.architecture.isEmpty)
        XCTAssertFalse(
            report.mountIssues.contains { $0.localizedCaseInsensitiveContains("detected architecture:") }
        )
    }

    func testMissingWriteSafetyProbeIsStrongAdvisoryWhenMountBackendExists() {
        let report = dependencyReport(
            toolResolver: { binary, _, _ in
                switch binary {
                case "ntfs-3g":
                    return "/tmp/ntfs-3g"
                case "mount_macfuse":
                    return "/tmp/mount_macfuse"
                case "mkntfs":
                    return "/tmp/mkntfs"
                case "ntfsfix":
                    return "/tmp/ntfsfix"
                default:
                    return nil
                }
            }
        )

        XCTAssertNil(report.ntfs3gProbePath)
        XCTAssertFalse(report.mountIssues.contains { $0.localizedCaseInsensitiveContains("ntfs-3g.probe") })
        XCTAssertTrue(report.advisoryNotes.contains { note in
            note.localizedCaseInsensitiveContains("ntfs-3g.probe not found")
                && note.localizedCaseInsensitiveContains("refuse writable mounts")
        })
    }

    func testAdHocInstalledAppWarnsThatFullDiskAccessMayNeedFreshApproval() {
        let report = dependencyReport(installedAppSignatureProvider: { "adhoc" })

        XCTAssertTrue(report.advisoryNotes.contains { note in
            note.localizedCaseInsensitiveContains("ad-hoc signed")
                && note.localizedCaseInsensitiveContains("removing and re-adding")
                && note.localizedCaseInsensitiveContains("/Applications/NTFS Access.app")
        })
    }

    func testStableLocalSigningIdentityExplainsFullDiskAccessShouldStickAfterFreshApproval() {
        let report = dependencyReport(installedAppSignatureProvider: { "Authority=NTFS Access Local Signing" })

        XCTAssertTrue(report.advisoryNotes.contains { note in
            note.localizedCaseInsensitiveContains("stable local signing identity")
                && note.localizedCaseInsensitiveContains("survive rebuilds")
        })
        XCTAssertFalse(report.advisoryNotes.contains { note in
            note.localizedCaseInsensitiveContains("ad-hoc signed")
        })
    }

    func testFormatterProbeOrdersExposeInstalledFilesystemBundlePriority() throws {
        let probeOrders = FileSystemPersonalityInspector.formatterProbeOrders(
            infoPlistPath: repositoryRoot()
                .appendingPathComponent("Packaging/Filesystems/ntfsaccess.fs/Contents/Info.plist")
                .path
        )

        XCTAssertEqual(probeOrders["Windows_NTFS"], 500)
        XCTAssertEqual(probeOrders["EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"], 500)
        XCTAssertEqual(probeOrders["Partitionless"], 3500)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsaccess-dependency-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func dependencyReport(
        requireRoot: Bool = false,
        macFUSEKernelLoaded: @escaping () -> Bool? = { true },
        architectureProvider: @escaping () -> String = { "arm64" },
        toolResolver: @escaping (String, Bool, [String]) -> String? = { binary, _, _ in
            switch binary {
            case "ntfs-3g":
                return "/Library/NTFSAccess/toolchain/bin/ntfs-3g"
            case "ntfs-3g.probe":
                return "/Library/NTFSAccess/toolchain/bin/ntfs-3g.probe"
            case "mkntfs":
                return "/Library/NTFSAccess/toolchain/sbin/mkntfs"
            case "ntfsfix":
                return "/Library/NTFSAccess/toolchain/bin/ntfsfix"
            case "ntfslabel":
                return "/Library/NTFSAccess/toolchain/bin/ntfslabel"
            case "mount_macfuse":
                return "/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse"
            default:
                return nil
            }
        },
        toolDiagnosticsResolver: @escaping (String, Bool, [String]) -> [String] = { _, _, _ in [] },
        installedAppSignatureProvider: @escaping () -> String = { "signed" }
    ) -> DependencyReport {
        DependencyChecker.run(
            requireRoot: requireRoot,
            macFUSEKernelLoaded: macFUSEKernelLoaded,
            architectureProvider: architectureProvider,
            toolResolver: toolResolver,
            toolDiagnosticsResolver: toolDiagnosticsResolver,
            formatterBundleInstalledProvider: { true },
            formatterPersonalityRegisteredProvider: { true },
            formatterProbeOrdersProvider: { ["Windows_NTFS": 500] },
            detectedNTFSPersonalitiesProvider: { [NTFSAccessPaths.formatterPersonalityName] },
            installedAppSignatureProvider: installedAppSignatureProvider,
            runningMountDaemonProgramProvider: { nil },
            installedMountWrapperUsesAppHelperProvider: { true }
        )
    }
}
