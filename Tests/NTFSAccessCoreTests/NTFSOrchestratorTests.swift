@testable import NTFSAccessCore
import NTFSAccessShared
import XCTest

final class NTFSOrchestratorTests: XCTestCase {
    func testVolumeDTOMapsReadWriteVolumeToGreenOpenInFinderState() {
        let transition = Date(timeIntervalSince1970: 1_000)
        let dto = ManagedVolumeState(
            deviceIdentifier: "disk4s1",
            stableIdentity: "volumeuuid-green",
            volumeName: "Passport",
            mountPoint: "/Volumes/Passport",
            isExternal: true,
            mode: .readWrite,
            reason: "",
            lastTransitionAt: transition
        ).toDTO()

        XCTAssertEqual(dto.presentationState, .readWriteVerified)
        XCTAssertEqual(dto.statusColor, .green)
        XCTAssertEqual(dto.primaryAction, .openInFinder)
        XCTAssertFalse(dto.isActionable)
        XCTAssertEqual(dto.lastCheckedAt, transition)
    }

    func testVolumeDTOMapsReadWriteWarningToYellowRescanState() {
        let dto = ManagedVolumeState(
            deviceIdentifier: "disk4s1",
            volumeName: "Passport",
            mountPoint: "/Volumes/Passport",
            isExternal: true,
            mode: .readWrite,
            reason: "retaining the last verified NTFS Access read-write state after transient scan failure",
            lastTransitionAt: Date(timeIntervalSince1970: 1_001)
        ).toDTO()

        XCTAssertEqual(dto.presentationState, .readWriteWarning)
        XCTAssertEqual(dto.statusColor, .yellow)
        XCTAssertEqual(dto.primaryAction, .rescan)
        XCTAssertTrue(dto.isActionable)
    }

    func testVolumeDTOMapsReadOnlyFallbackToYellowWritableTakeoverState() {
        let dto = ManagedVolumeState(
            deviceIdentifier: "disk4s1",
            volumeName: "Passport",
            mountPoint: "/Volumes/NTFSAccess-disk4s1",
            isExternal: true,
            mode: .readOnly,
            reason: "mounted read-only fallback after writable NTFS Access mount failed",
            lastTransitionAt: Date(timeIntervalSince1970: 1_002)
        ).toDTO()

        XCTAssertEqual(dto.presentationState, .readOnlyFallback)
        XCTAssertEqual(dto.statusColor, .yellow)
        XCTAssertEqual(dto.primaryAction, .retryWritableTakeover)
        XCTAssertTrue(dto.isActionable)
    }

    func testVolumeDTOMapsNativeReadOnlyToYellowWritableTakeoverState() {
        let dto = ManagedVolumeState(
            deviceIdentifier: "disk4s1",
            volumeName: "Passport",
            mountPoint: "/Volumes/Passport",
            isExternal: true,
            mode: .readOnly,
            reason: "restored native macOS read-only mount after writable takeover failed",
            lastTransitionAt: Date(timeIntervalSince1970: 1_003)
        ).toDTO()

        XCTAssertEqual(dto.presentationState, .nativeReadOnly)
        XCTAssertEqual(dto.statusColor, .yellow)
        XCTAssertEqual(dto.primaryAction, .retryWritableTakeover)
        XCTAssertTrue(dto.isActionable)
    }

    func testVolumeDTOMapsRawAccessDeniedToRedFullDiskAccessState() {
        let dto = ManagedVolumeState(
            deviceIdentifier: "disk4s1",
            volumeName: "Passport",
            mountPoint: "",
            isExternal: true,
            mode: .unmounted,
            reason: "Error opening '/dev/disk4s1': Operation not permitted",
            lastTransitionAt: Date(timeIntervalSince1970: 1_004)
        ).toDTO()

        XCTAssertEqual(dto.presentationState, .rawAccessDenied)
        XCTAssertEqual(dto.statusColor, .red)
        XCTAssertEqual(dto.primaryAction, .openFullDiskAccess)
        XCTAssertTrue(dto.isActionable)
    }

    func testVolumeDTOMapsUnsafeNTFSToRedWindowsCleanupGuidanceState() {
        let dto = ManagedVolumeState(
            deviceIdentifier: "disk4s1",
            volumeName: "Passport",
            mountPoint: "/Volumes/Passport",
            isExternal: true,
            mode: .readOnly,
            reason: "dirty NTFS journal; hibernated Windows session detected",
            lastTransitionAt: Date(timeIntervalSince1970: 1_005)
        ).toDTO()

        XCTAssertEqual(dto.presentationState, .unsafeNTFS)
        XCTAssertEqual(dto.statusColor, .red)
        XCTAssertEqual(dto.primaryAction, .showWindowsCleanupGuidance)
        XCTAssertTrue(dto.isActionable)
    }

    func testVolumeDTOMapsMacFUSEUnavailableToRedGuidanceState() {
        let dto = ManagedVolumeState(
            deviceIdentifier: "disk4s1",
            volumeName: "Passport",
            mountPoint: "",
            isExternal: true,
            mode: .unmounted,
            reason: "macFUSE helper not available",
            lastTransitionAt: Date(timeIntervalSince1970: 1_006)
        ).toDTO()

        XCTAssertEqual(dto.presentationState, .macFUSEUnavailable)
        XCTAssertEqual(dto.statusColor, .red)
        XCTAssertEqual(dto.primaryAction, .showMacFUSEGuidance)
        XCTAssertTrue(dto.isActionable)
    }

    func testVolumeDTOMapsDisconnectedAndScanningStatesToGray() {
        let disconnected = ManagedVolumeState(
            deviceIdentifier: "disk4s1",
            volumeName: "Passport",
            mountPoint: "",
            isExternal: true,
            mode: .unmounted,
            reason: "device disconnected",
            lastTransitionAt: Date(timeIntervalSince1970: 1_007)
        ).toDTO()
        let scanning = ManagedVolumeState(
            deviceIdentifier: "disk4s2",
            volumeName: "Passport2",
            mountPoint: "",
            isExternal: true,
            mode: .unmounted,
            reason: "scan running",
            lastTransitionAt: Date(timeIntervalSince1970: 1_008)
        ).toDTO()

        XCTAssertEqual(disconnected.presentationState, .disconnected)
        XCTAssertEqual(disconnected.statusColor, .gray)
        XCTAssertEqual(disconnected.primaryAction, .none)
        XCTAssertFalse(disconnected.isActionable)
        XCTAssertEqual(scanning.presentationState, .scanning)
        XCTAssertEqual(scanning.statusColor, .gray)
        XCTAssertEqual(scanning.primaryAction, .none)
        XCTAssertFalse(scanning.isActionable)
    }

    func testMountedNativeReadOnlySafeVolumeStopsBeforeTakeoverWhenRawDeviceAccessCheckIsDenied() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        mounter.rawDeviceReadable = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            rawAccessReadinessCheckInterval: 0
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [])
        XCTAssertEqual(result.health, .degradedReadOnly)
        XCTAssertEqual(result.volumes.first?.mode, .readOnly)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/Passport")
        XCTAssertTrue(result.volumes.first?.reason.contains("raw disk access is not authorized") == true)
        XCTAssertEqual(result.volumes.first?.toDTO().presentationState, .rawAccessDenied)
    }

    func testNativeReadOnlyRawAccessDenialIsNotRetriedOnEveryScan() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(
            safeForWrite: false,
            reason: "Error opening '/dev/disk4s1': Operation not permitted"
        ))
        let mounter = FakeMounter(scanner: scanner)
        mounter.rawDeviceReadable = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true },
            rawAccessReadinessCheckInterval: 0
        )

        let firstResult = orchestrator.reconcile()
        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(firstResult.health, .degradedReadOnly)
        XCTAssertEqual(secondResult.health, .degradedReadOnly)
        XCTAssertEqual(mounter.rawReadCheckCount, 1)
        XCTAssertEqual(mounter.calls, [])
    }

    func testNativeReadOnlyRawAccessBackoffSurvivesDiskRenumberingWhenDiskUUIDMatches() {
        let initialVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk4s1",
            diskUUID: "2D253235-C29F-4EDA-B308-13F6DB9DA6DD",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let renumberedVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk9s1",
            diskUUID: "2D253235-C29F-4EDA-B308-13F6DB9DA6DD",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(
            safeForWrite: false,
            reason: "Error opening '/dev/disk4s1': Operation not permitted"
        ))
        let mounter = FakeMounter(scanner: scanner)
        mounter.rawDeviceReadable = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true },
            rawAccessReadinessCheckInterval: 60
        )

        let firstResult = orchestrator.reconcile()
        scanner.volume = renumberedVolume
        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(firstResult.volumes.first?.deviceIdentifier, "disk4s1")
        XCTAssertEqual(secondResult.volumes.first?.deviceIdentifier, "disk9s1")
        XCTAssertEqual(secondResult.volumes.first?.stableIdentity, "diskuuid-2D253235-C29F-4EDA-B308-13F6DB9DA6DD")
        XCTAssertEqual(mounter.rawReadCheckCount, 1)
        XCTAssertEqual(mounter.calls, [])
    }

    func testMountedNativeReadOnlySafeVolumeCanBeTakenOverWhenRawDeviceAccessIsAvailable() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            rawAccessReadinessCheckInterval: 0
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountUsingRegisteredPersonality(disk4s1,false)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/Passport")
    }

    func testNativeReadOnlyVolumeRetriesTakeoverAfterRawAccessBecomesAvailable() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        mounter.rawDeviceReadable = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true },
            rawAccessReadinessCheckInterval: 0
        )

        _ = orchestrator.reconcile()
        mounter.rawDeviceReadable = true
        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.rawReadCheckCount, 3)
        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountUsingRegisteredPersonality(disk4s1,false)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
    }

    func testNativeReadOnlyFallbackRetriesTakeoverAfterPreviousTakeoverFailure() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let temporaryError = AppError(message: "temporary raw disk denial")
        mounter.mountRegisteredPersonalityError = temporaryError
        mounter.mountReadWriteError = AppError(message: "temporary raw disk denial")
        mounter.mountReadOnlyError = AppError(message: "temporary raw disk denial")
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        let firstResult = orchestrator.reconcile()
        mounter.mountRegisteredPersonalityError = nil
        mounter.mountReadWriteError = nil
        mounter.mountReadOnlyError = nil
        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [
            "unmount(disk4s1,true)",
            "mountUsingRegisteredPersonality(disk4s1,false)",
            "mountReadWrite(disk4s1)",
            "mountReadOnly(disk4s1)",
            "mountNativeReadOnly(disk4s1)",
            "unmount(disk4s1,true)",
            "mountUsingRegisteredPersonality(disk4s1,false)"
        ])
        XCTAssertEqual(firstResult.health, .degradedReadOnly)
        XCTAssertEqual(secondResult.health, .healthy)
        XCTAssertEqual(secondResult.volumes.first?.mode, .readWrite)
    }

    func testUnsafeNativeReadOnlyVolumeIsRetainedWhenRawDeviceAccessIsDenied() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Unsafe",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: false, reason: "dirty NTFS journal"))
        let mounter = FakeMounter(scanner: scanner)
        mounter.rawDeviceReadable = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        let firstResult = orchestrator.reconcile()
        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [])
        XCTAssertEqual(firstResult.health, .degradedReadOnly)
        XCTAssertEqual(firstResult.volumes.first?.mode, .readOnly)
        XCTAssertEqual(firstResult.volumes.first?.mountPoint, "/Volumes/Unsafe")
        XCTAssertTrue(firstResult.volumes.first?.reason.contains("raw disk access is not authorized") == true)
        XCTAssertEqual(secondResult.health, .degradedReadOnly)
        XCTAssertEqual(secondResult.volumes.first?.mode, .readOnly)
    }

    func testUnsafeNativeReadOnlyVolumeIsRestoredWithoutRepeatedTakeoverAttemptsWhenRawDeviceAccessIsAvailable() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Unsafe",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: false, reason: "dirty NTFS journal"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        let firstResult = orchestrator.reconcile()
        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountNativeReadOnly(disk4s1)"])
        XCTAssertEqual(firstResult.health, .degradedReadOnly)
        XCTAssertEqual(firstResult.volumes.first?.mode, .readOnly)
        XCTAssertEqual(secondResult.health, .degradedReadOnly)
        XCTAssertEqual(secondResult.volumes.first?.mode, .readOnly)
    }

    func testUnmountedBundleManagedSafeVolumeMountsThroughRegisteredFilesystemPersonality() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfsaccess",
            filesystemName: "Windows NT File System (NTFS Access)",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["mountUsingRegisteredPersonality(disk4s1,false)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/Passport")
    }

    func testRegisteredFilesystemRootOnlyWritableResultFallsBackToDirectWritableMount() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryDirectory.path)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let rootOnlyMountPoint = temporaryDirectory.appendingPathComponent("NTFSAccess-disk4s1")
        try FileManager.default.createDirectory(at: rootOnlyMountPoint, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rootOnlyMountPoint.path)

        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfsaccess",
            filesystemName: "Windows NT File System (NTFS Access)",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        mounter.registeredPersonalityMountPointOverride = rootOnlyMountPoint.path
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            mountConfiguration: MountConfiguration(mountRoot: temporaryDirectory.path),
            dependencyCheck: Self.readyDependencies
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [
            "mountUsingRegisteredPersonality(disk4s1,false)",
            "unmount(disk4s1,true)",
            "mountReadWrite(disk4s1)"
        ])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/NTFSAccess-disk4s1")
    }

    func testMountedBundleManagedReadOnlySafeVolumeIsRemountedWritable() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfsaccess",
            filesystemName: "Windows NT File System (NTFS Access)",
            mountPoint: "/Volumes/NTFSAccess-disk4s1",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountUsingRegisteredPersonality(disk4s1,false)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.reason, "")
    }

    func testKnownManagedWritableMountReportedReadOnlyStaysReadWriteWhenUserWriteProbeSucceeds() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-disk4s1",
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        let firstResult = orchestrator.reconcile()
        mounter.calls.removeAll()
        scanner.volume = initialVolume.copy(mountPoint: initialVolume.mountPoint, isMounted: true, isWritable: false)

        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(firstResult.health, .healthy)
        XCTAssertEqual(secondResult.health, .healthy)
        XCTAssertEqual(secondResult.volumes.first?.mode, .readWrite)
        XCTAssertEqual(secondResult.volumes.first?.reason, "")
        XCTAssertEqual(mounter.calls, [])
    }

    func testRegisteredFilesystemReadOnlyResultFallsBackToDirectWritableMount() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfsaccess",
            filesystemName: "Windows NT File System (NTFS Access)",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        mounter.registeredPersonalityMountsReadOnly = true
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [
            "mountUsingRegisteredPersonality(disk4s1,false)",
            "unmount(disk4s1,true)",
            "mountReadWrite(disk4s1)"
        ])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/NTFSAccess-disk4s1")
    }

    func testNativeReadOnlyNTFSVolumeTakeoverUsesRegisteredFilesystemPersonality() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            rawAccessReadinessCheckInterval: 0
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountUsingRegisteredPersonality(disk4s1,false)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/Passport")
    }

    func testNativeReadOnlyTakeoverStopsBeforeRegisteredFilesystemWhenRawWriteProbeIsDenied() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(
            safeForWrite: false,
            reason: "Error opening '/dev/disk4s1': Operation not permitted"
        ))
        let mounter = FakeMounter(scanner: scanner)
        mounter.rawDeviceReadable = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            rawAccessReadinessCheckInterval: 0
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [])
        XCTAssertEqual(result.health, .degradedReadOnly)
        XCTAssertEqual(result.volumes.first?.mode, .readOnly)
        XCTAssertEqual(result.volumes.first?.toDTO().presentationState, .rawAccessDenied)
    }

    func testNativeReadOnlyTakeoverStopsAfterRawDiskDenialAndRestoresNativeReadOnly() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        mounter.rawDeviceReadable = false
        mounter.mountRegisteredPersonalityError = AppError(
            message: "diskutil mount failed for disk4s1: Volume on disk4s1 failed to mount"
        )
        mounter.mountReadWriteError = AppError(
            message: "Mount failed for disk4s1: macOS denied raw disk access to /dev/disk4s1."
        )
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            nativeReadOnlyTakeoverRetryInterval: 300,
            rawAccessReadinessCheckInterval: 0
        )

        let firstResult = orchestrator.reconcile()
        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [])
        XCTAssertEqual(firstResult.health, .degradedReadOnly)
        XCTAssertEqual(firstResult.volumes.first?.mode, .readOnly)
        XCTAssertEqual(firstResult.volumes.first?.mountPoint, "/Volumes/Passport")
        XCTAssertTrue(firstResult.volumes.first?.reason.contains("raw disk access is not authorized") == true)
        XCTAssertEqual(secondResult.health, .degradedReadOnly)
        XCTAssertEqual(secondResult.volumes.first?.mode, .readOnly)
    }

    func testNativeReadOnlyTakeoverContinuesWhenDiskutilInfoTimesOutAfterUnmount() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter
        )
        scanner.infoErrorAfterUnmount = AppError(message: "Command timed out: /usr/sbin/diskutil info -plist /dev/disk4s1")

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountReadWrite(disk4s1)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/NTFSAccess-disk4s1")
    }

    func testScanListFailureRefreshesKnownVolumeDirectlyInsteadOfLeavingStaleUnmountedState() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        let firstResult = orchestrator.reconcile()
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")

        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(firstResult.health, .healthy)
        XCTAssertEqual(secondResult.health, .healthy)
        XCTAssertEqual(secondResult.lastError, "")
        XCTAssertEqual(secondResult.volumes.first?.mode, .readWrite)
        XCTAssertEqual(secondResult.volumes.first?.mountPoint, "/Volumes/Passport")
    }

    func testScanFailureKeepsHealthyKnownStateWhenDirectRefreshAlsoGlitches() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        let firstResult = orchestrator.reconcile()
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")
        scanner.infoError = AppError(message: "The data could not be read because it is not in the correct format.")

        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(firstResult.health, .healthy)
        XCTAssertEqual(secondResult.health, .healthy)
        XCTAssertEqual(secondResult.lastError, "")
        XCTAssertEqual(secondResult.volumes.first?.mode, .readWrite)
        XCTAssertEqual(secondResult.volumes.first?.mountPoint, "/Volumes/Passport")
    }

    func testScanFailureDoesNotRetainReadWriteStateWhenManagedMountPointDisappeared() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { path in path != "/Volumes/Passport" },
            managedMountPointIsActive: { _ in true }
        )

        _ = orchestrator.reconcile()
        mounter.mountRegisteredPersonalityError = AppError(message: "temporary remount failure")
        mounter.mountReadWriteError = AppError(message: "temporary remount failure")
        scanner.volume = scanner.volume.copy(mountPoint: "/Volumes/Passport", isMounted: true, isWritable: true)
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")

        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(secondResult.health, .error)
        XCTAssertEqual(secondResult.volumes.first?.mode, .unmounted)
        XCTAssertTrue(secondResult.volumes.first?.reason.contains("managed mount point is missing") == true)
        XCTAssertTrue(secondResult.volumes.first?.reason.contains("temporary remount failure") == true)
    }

    func testScanFailureDoesNotRetainCollapsedManagedMountWhenSiblingRecoveryFails() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let firstMountPoint = temporaryDirectory.appendingPathComponent("NTFSAccess-disk13s2")
        let secondMountPoint = temporaryDirectory.appendingPathComponent("NTFSAccess-disk13s3")
        try FileManager.default.createDirectory(at: secondMountPoint, withIntermediateDirectories: true)

        let firstVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s2",
            diskUUID: "E933632A-F931-4AB9-8A69-FA76FA7F3725",
            volumeName: "HP_NTFS_A",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: firstMountPoint.path,
            isMounted: true,
            isWritable: true
        )
        let secondVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s3",
            diskUUID: "5C5AECB7-A1B0-4F8A-8B6E-C4449B7323D8",
            volumeName: "HP_NTFS_B",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: secondMountPoint.path,
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volumes: [firstVolume, secondVolume])
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { path in path == secondMountPoint.path },
            managedMountPointIsActive: { path in path == secondMountPoint.path }
        )

        _ = orchestrator.reconcile()
        mounter.mountRegisteredPersonalityError = AppError(message: "temporary remount failure")
        mounter.mountReadWriteError = AppError(message: "temporary remount failure")
        scanner.volumes = [
            firstVolume.copy(mountPoint: firstMountPoint.path, isMounted: true, isWritable: true),
            secondVolume.copy(mountPoint: secondMountPoint.path, isMounted: true, isWritable: true)
        ]
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")

        let result = orchestrator.reconcile()

        XCTAssertEqual(result.health, .error)
        XCTAssertEqual(result.managedVolumeCount, 2)
        XCTAssertEqual(result.volumes.count, 2)
        let collapsed = result.volumes.first { $0.deviceIdentifier == "disk13s2" }
        let healthy = result.volumes.first { $0.deviceIdentifier == "disk13s3" }
        XCTAssertEqual(collapsed?.mode, .unmounted)
        XCTAssertTrue(collapsed?.reason.contains("managed mount point is missing") == true)
        XCTAssertTrue(collapsed?.reason.contains("temporary remount failure") == true)
        XCTAssertEqual(healthy?.mode, .readWrite)
        XCTAssertEqual(healthy?.mountPoint, secondMountPoint.path)
    }

    func testScanFailureRetainsKnownUnmountedNTFSVolumesWhenDirectRefreshAlsoGlitches() {
        let firstVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk12s2",
            diskUUID: "E933632A-F931-4AB9-8A69-FA76FA7F3725",
            volumeName: "HP_NTFS_A",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let secondVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk12s3",
            diskUUID: "5C5AECB7-A1B0-4F8A-8B6E-C4449B7323D8",
            volumeName: "HP_NTFS_B",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volumes: [firstVolume, secondVolume])
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        mounter.mountRegisteredPersonalityError = AppError(message: "diskutil mount failed")
        mounter.mountReadWriteError = AppError(message: "temporary direct mount failure")
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in false },
            managedMountPointIsActive: { _ in false }
        )

        _ = orchestrator.reconcile()
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")
        scanner.infoError = AppError(message: "The data could not be read because it is not in the correct format.")

        let result = orchestrator.reconcile()

        XCTAssertEqual(result.health, .error)
        XCTAssertEqual(result.managedVolumeCount, 2)
        XCTAssertEqual(Set(result.volumes.map(\.deviceIdentifier)), ["disk12s2", "disk12s3"])
        XCTAssertEqual(Set(result.volumes.map(\.mode)), [.readOnly])
        XCTAssertTrue(result.lastError.contains("Scan failed"))
    }

    func testScanFailureDoesNotRetainReadWriteStateWhenManagedMountPointIsOnlyAStaleDirectory() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { path in path == "/Volumes/Passport" },
            managedMountPointIsActive: { _ in false }
        )

        _ = orchestrator.reconcile()
        mounter.mountRegisteredPersonalityError = AppError(message: "temporary remount failure")
        mounter.mountReadWriteError = AppError(message: "temporary remount failure")
        scanner.volume = scanner.volume.copy(mountPoint: "/Volumes/Passport", isMounted: true, isWritable: true)
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")

        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(secondResult.health, .error)
        XCTAssertEqual(secondResult.volumes.first?.mode, .unmounted)
        XCTAssertTrue(secondResult.volumes.first?.reason.contains("active filesystem mount") == true)
        XCTAssertTrue(secondResult.volumes.first?.reason.contains("temporary remount failure") == true)
    }

    func testScanFailureRecoversCollapsedKnownManagedMountUsingLastKnownState() {
        let initialVolume = DiskVolume.testVolume(
            diskUUID: "2D253235-C29F-4EDA-B308-13F6DB9DA6DD",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        var activeMount = true
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in activeMount }
        )

        _ = orchestrator.reconcile()
        mounter.calls.removeAll()
        activeMount = false
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountReadWrite(disk4s1)"])
        XCTAssertEqual(result.health, .degradedReadOnly)
        XCTAssertEqual(result.volumes.first?.mode, .readOnly)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/NTFSAccess-diskuuid-2D253235-C29F-4EDA-B308-13F6DB9DA6DD")
    }

    func testScanFailureRetainsCollapsedManagedMountOnceWhenDirectIdentityCannotBeVerified() {
        let initialVolume = DiskVolume.testVolume(
            diskUUID: "2D253235-C29F-4EDA-B308-13F6DB9DA6DD",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        var activeMount = true
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in activeMount }
        )

        _ = orchestrator.reconcile()
        mounter.calls.removeAll()
        activeMount = false
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")
        scanner.infoError = AppError(message: "disk info unavailable")

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [])
        XCTAssertEqual(result.health, .warning)
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertTrue(result.lastWarning.contains("temporarily inconclusive"), result.lastWarning)
    }

    func testRepeatedDiskutilTimeoutScanFailureRecoversCollapsedManagedMountWithoutDirectIdentityRefresh() {
        let initialVolume = DiskVolume.testVolume(
            diskUUID: "2D253235-C29F-4EDA-B308-13F6DB9DA6DD",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        var activeMount = true
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in activeMount }
        )

        _ = orchestrator.reconcile()
        mounter.calls.removeAll()
        activeMount = false
        scanner.listError = AppError(message: "Command timed out: /usr/sbin/diskutil list -plist")
        scanner.infoError = AppError(message: "Command timed out: /usr/sbin/diskutil info -plist /dev/disk4s1")

        let warningResult = orchestrator.reconcile()
        let result = orchestrator.reconcile()

        XCTAssertEqual(warningResult.health, .warning)
        XCTAssertEqual(warningResult.volumes.first?.mode, .readWrite)
        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountReadWrite(disk4s1)"])
        XCTAssertEqual(result.health, .error)
        XCTAssertEqual(result.volumes.first?.mode, .unmounted)
        XCTAssertEqual(result.volumes.first?.stableIdentity, "diskuuid-2D253235-C29F-4EDA-B308-13F6DB9DA6DD")
        XCTAssertTrue(result.lastError.contains("did not produce a writable mount") == true, result.lastError)
    }

    func testUnmountedWritableMountSuccessWithInfoRefreshFailureDoesNotReportHealthy() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter
        )
        scanner.infoErrorAfterWritableMount = AppError(message: "diskutil info unavailable after mount")

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["mountReadWrite(disk4s1)"])
        XCTAssertEqual(result.health, .error)
        XCTAssertEqual(result.volumes.first?.mode, .unmounted)
        XCTAssertTrue(result.lastError.contains("mount command returned success but volume not mounted") == true, result.lastError)
    }

    func testUnmountedWritableMountWithInfoRefreshFailureUsesActiveMountProbeBeforeReportingUnhealthy() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let expectedMountPoint = "/Volumes/NTFSAccess-disk4s1"
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter,
            mountPathExists: { $0 == expectedMountPoint },
            managedMountPointIsActive: { $0 == expectedMountPoint }
        )
        scanner.infoErrorAfterWritableMount = AppError(message: "diskutil info unavailable after mount")

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["mountReadWrite(disk4s1)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.mountPoint, expectedMountPoint)
    }

    func testMountedWritableVolumeWithFailedUserWriteProbeDoesNotReportReadWrite() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-disk4s1",
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: { _, _ in .failure(AppError(message: "write denied")) },
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [
            "unmount(disk4s1,true)",
            "mountUsingRegisteredPersonality(disk4s1,false)",
            "unmount(disk4s1,true)",
            "mountReadWrite(disk4s1)"
        ])
        XCTAssertEqual(result.health, .degradedReadOnly)
        XCTAssertEqual(result.volumes.first?.mode, .readOnly)
        XCTAssertTrue(result.volumes.first?.reason.contains("did not produce a writable mount") == true, result.volumes.first?.reason ?? "")
    }

    func testKnownManagedWritableMountRetainsReadWriteAcrossTransientWriteProbeTimeout() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-disk4s1",
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        var shouldTimeout = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: { _, _ in
                shouldTimeout
                    ? .failure(AppError(message: "Command timed out while waiting for /bin/launchctl asuser write probe"))
                    : .success(())
            },
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        let firstResult = orchestrator.reconcile()
        mounter.calls.removeAll()
        shouldTimeout = true
        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(firstResult.health, .healthy)
        XCTAssertEqual(firstResult.volumes.first?.mode, .readWrite)
        XCTAssertEqual(secondResult.health, .warning)
        XCTAssertEqual(secondResult.warningCount, 1)
        XCTAssertTrue(secondResult.lastWarning.contains("retaining the last verified NTFS Access read-write state"), secondResult.lastWarning)
        XCTAssertEqual(secondResult.degradedVolumeCount, 0)
        XCTAssertEqual(secondResult.volumes.first?.mode, .readWrite)
        XCTAssertTrue(secondResult.volumes.first?.reason.contains("retaining the last verified NTFS Access read-write state") == true, secondResult.volumes.first?.reason ?? "")
        XCTAssertEqual(mounter.calls, [])
    }

    func testDuplicateVolumeUUIDsUseLayoutDisambiguatedMountIdentities() {
        let firstVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk12s2",
            volumeUUID: "1A2B3C4D-1111-2222-3333-444455556666",
            parentWholeDisk: "disk12",
            partitionMapPartitionOffset: 1_048_576,
            size: 2_000_000_000,
            volumeName: "Clone",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let secondVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s2",
            volumeUUID: "1A2B3C4D-1111-2222-3333-444455556666",
            parentWholeDisk: "disk13",
            partitionMapPartitionOffset: 2_097_152,
            size: 4_000_000_000,
            volumeName: "Clone",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volumes: [firstVolume, secondVolume])
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.count, 2)
        XCTAssertEqual(Set(result.volumes.map(\.mode)), [.readWrite])

        let stableIdentities = Set(result.volumes.map(\.stableIdentity))
        XCTAssertEqual(stableIdentities.count, 2)
        XCTAssertTrue(stableIdentities.contains("volumeuuid-1A2B3C4D-1111-2222-3333-444455556666-layout-disk12-1048576-2000000000"))
        XCTAssertTrue(stableIdentities.contains("volumeuuid-1A2B3C4D-1111-2222-3333-444455556666-layout-disk13-2097152-4000000000"))

        let mountPoints = Set(result.volumes.map(\.mountPoint))
        XCTAssertEqual(mountPoints.count, 2)
        XCTAssertTrue(mountPoints.contains("/Volumes/NTFSAccess-volumeuuid-1A2B3C4D-1111-2222-3333-444455556666-layout-disk12-1048576-2000000000"))
        XCTAssertTrue(mountPoints.contains("/Volumes/NTFSAccess-volumeuuid-1A2B3C4D-1111-2222-3333-444455556666-layout-disk13-2097152-4000000000"))
    }

    func testTargetedRefreshPreservesPhysicalDriveMetadataFromPreviousState() {
        let initialVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s2",
            diskUUID: "4C0C0133-D379-45D1-ADDA-7BA72266BB22",
            parentWholeDisk: "disk13",
            parentWholeDiskName: "ESD-S1C",
            volumeName: "NVME A",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-disk13s2",
            isMounted: true,
            isWritable: true
        )
        let targetedInfoVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s2",
            diskUUID: "4C0C0133-D379-45D1-ADDA-7BA72266BB22",
            parentWholeDisk: "disk13",
            volumeName: "NVME A",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-disk13s2",
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: FakeMounter(scanner: scanner),
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        let firstResult = orchestrator.reconcile()
        scanner.volume = targetedInfoVolume
        let targetedResult = orchestrator.reconcileKnownVolume(stableIdentity: initialVolume.stableIdentity)

        XCTAssertEqual(firstResult.volumes.first?.parentWholeDiskName, "ESD-S1C")
        XCTAssertEqual(targetedResult.volumes.first?.parentWholeDisk, "disk13")
        XCTAssertEqual(targetedResult.volumes.first?.parentWholeDiskName, "ESD-S1C")
    }

    func testHealthyReadWriteReconcileUpgradesPlaceholderPhysicalDriveName() {
        let placeholderVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s2",
            diskUUID: "4C0C0133-D379-45D1-ADDA-7BA72266BB22",
            parentWholeDisk: "disk13",
            parentWholeDiskName: "disk13",
            volumeName: "NVME A",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-disk13s2",
            isMounted: true,
            isWritable: true
        )
        let enrichedVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s2",
            diskUUID: "4C0C0133-D379-45D1-ADDA-7BA72266BB22",
            parentWholeDisk: "disk13",
            parentWholeDiskName: "ESD-S1C",
            volumeName: "NVME A",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-disk13s2",
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: placeholderVolume)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe")),
            mounter: FakeMounter(scanner: scanner),
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        XCTAssertEqual(orchestrator.reconcile().volumes.first?.parentWholeDiskName, "disk13")

        scanner.volume = enrichedVolume
        let result = orchestrator.reconcile()

        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.parentWholeDiskName, "ESD-S1C")
    }

    func testVerifiedManagedWritableMountStaysHealthyAcrossRepeatedVerificationProbes() {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-disk4s1",
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true },
            now: { currentDate }
        )

        let firstResult = orchestrator.reconcile()
        currentDate = currentDate.addingTimeInterval(11)
        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(firstResult.health, .healthy)
        XCTAssertEqual(secondResult.health, .healthy)
        XCTAssertEqual(secondResult.warningCount, 0)
        XCTAssertEqual(secondResult.lastWarning, "")
        XCTAssertEqual(secondResult.degradedVolumeCount, 0)
        XCTAssertEqual(secondResult.volumes.first?.mode, .readWrite)
    }

    func testScanFailureDropsKnownStateWhenDirectRefreshFindsDifferentStableIdentityOnSameDiskNode() {
        let initialVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk12s2",
            diskUUID: "E933632A-F931-4AB9-8A69-FA76FA7F3725",
            volumeName: "HP_NTFS_A",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-diskuuid-E933632A-F931-4AB9-8A69-FA76FA7F3725",
            isMounted: true,
            isWritable: true
        )
        let replacementVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk12s2",
            diskUUID: "44F90E9B-83CE-4BC7-BBD1-2A2F895E060A",
            volumeName: "OTHER_NTFS",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        _ = orchestrator.reconcile()
        mounter.calls.removeAll()
        scanner.volume = replacementVolume
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.managedVolumeCount, 0)
        XCTAssertEqual(result.volumes.count, 0)
    }

    func testEmptyScanRetainsActiveKnownManagedMount() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let mountConfiguration = MountConfiguration(mountRoot: temporaryDirectory.path)
        let volume = DiskVolume.testVolume(
            deviceIdentifier: "disk12s2",
            diskUUID: "FB66280B-1743-4B91-A5A1-4567CF9A4B37",
            volumeName: "gg",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: nil,
            isMounted: true,
            isWritable: true
        )
        let managedMountPoint = mountConfiguration.mountPoint(for: volume)
        try FileManager.default.createDirectory(atPath: managedMountPoint, withIntermediateDirectories: true)
        let managedVolume = volume.copy(
            mountPoint: managedMountPoint,
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: managedVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            mountConfiguration: mountConfiguration,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { $0 == managedVolume.mountPoint ?? "" },
            managedMountPointIsActive: { $0 == managedVolume.mountPoint ?? "" }
        )

        let firstResult = orchestrator.reconcile()
        scanner.volumes = []
        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(firstResult.health, .healthy)
        XCTAssertEqual(secondResult.health, .healthy)
        XCTAssertEqual(secondResult.managedVolumeCount, 1)
        XCTAssertEqual(secondResult.volumes.first?.deviceIdentifier, "disk12s2")
        XCTAssertEqual(secondResult.volumes.first?.stableIdentity, "diskuuid-FB66280B-1743-4B91-A5A1-4567CF9A4B37")
        XCTAssertEqual(secondResult.volumes.first?.mode, .readWrite)
    }

    func testEmptyScanDoesNotRetainKnownManagedMountAfterMountDisappears() {
        let managedVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk12s2",
            diskUUID: "FB66280B-1743-4B91-A5A1-4567CF9A4B37",
            volumeName: "gg",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-diskuuid-FB66280B-1743-4B91-A5A1-4567CF9A4B37",
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: managedVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        var activeMount = true
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in activeMount },
            managedMountPointIsActive: { _ in activeMount }
        )

        _ = orchestrator.reconcile()
        activeMount = false
        scanner.volumes = []
        let result = orchestrator.reconcile()

        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.managedVolumeCount, 0)
        XCTAssertEqual(result.volumes.count, 0)
    }

    func testScanFailureRecoversOnlyCollapsedManagedSiblingInMultiDriveSetup() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let firstMountPoint = temporaryDirectory.appendingPathComponent("NTFSAccess-disk13s2")
        let secondMountPoint = temporaryDirectory.appendingPathComponent("NTFSAccess-disk13s3")
        try FileManager.default.createDirectory(at: firstMountPoint, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondMountPoint, withIntermediateDirectories: true)

        let firstVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s2",
            diskUUID: "E933632A-F931-4AB9-8A69-FA76FA7F3725",
            volumeName: "HP_NTFS_A",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: firstMountPoint.path,
            isMounted: true,
            isWritable: true
        )
        let secondVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s3",
            diskUUID: "5C5AECB7-A1B0-4F8A-8B6E-C4449B7323D8",
            volumeName: "HP_NTFS_B",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: secondMountPoint.path,
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volumes: [firstVolume, secondVolume])
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        var collapsedSecondMount = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            mountConfiguration: MountConfiguration(mountRoot: temporaryDirectory.path),
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { path in !collapsedSecondMount || path != secondMountPoint.path }
        )

        _ = orchestrator.reconcile()
        mounter.calls.removeAll()
        collapsedSecondMount = true
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["unmount(disk13s3,true)", "mountUsingRegisteredPersonality(disk13s3,false)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.managedVolumeCount, 2)
        let first = result.volumes.first { $0.deviceIdentifier == "disk13s2" }
        let second = result.volumes.first { $0.deviceIdentifier == "disk13s3" }
        XCTAssertEqual(first?.mode, .readWrite)
        XCTAssertEqual(first?.mountPoint, firstMountPoint.path)
        XCTAssertEqual(second?.mode, .readWrite)
    }

    func testKnownVolumeRefreshUpdatesLabelAfterReformatWhenGlobalScanGlitches() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        _ = orchestrator.reconcile()
        scanner.volume = scanner.volume.copy(
            volumeName: "HP_NTFS_A",
            mediaName: "HP_NTFS_A",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")

        let result = orchestrator.reconcile()

        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.volumeName, "HP_NTFS_A")
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
    }

    func testKnownVolumeRefreshDropsStateAfterVolumeIsReformattedAwayFromNTFSWhenGlobalScanGlitches() {
        let samsungNTFS = DiskVolume.testVolume(
            deviceIdentifier: "disk12s2",
            volumeName: "SAMSUNG_NTFS",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-disk12s2",
            isMounted: true,
            isWritable: true
        )
        let hpNTFS = DiskVolume.testVolume(
            deviceIdentifier: "disk13s2",
            volumeName: "HP_NTFS_A",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: "/Volumes/NTFSAccess-disk13s2",
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volumes: [samsungNTFS, hpNTFS])
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        _ = orchestrator.reconcile()
        scanner.volumes = [
            samsungNTFS.copy(
                volumeName: "APFS_TOMORROW",
                mediaName: "APFS_TOMORROW",
                filesystemType: "apfs",
                filesystemName: "APFS",
                mountPoint: "/Volumes/APFS_TOMORROW",
                isMounted: true,
                isWritable: true
            ),
            hpNTFS
        ]
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")

        let result = orchestrator.reconcile()

        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.managedVolumeCount, 1)
        XCTAssertEqual(result.volumes.map(\.deviceIdentifier), ["disk13s2"])
        XCTAssertEqual(result.volumes.first?.volumeName, "HP_NTFS_A")
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertFalse(result.lastError.contains("SAMSUNG_NTFS"))
    }

    func testScanListFailureWithPartialDirectRefreshKeepsUnrefreshedSiblingState() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let firstMountPoint = temporaryDirectory.appendingPathComponent("NTFSAccess-disk13s2")
        let secondMountPoint = temporaryDirectory.appendingPathComponent("NTFSAccess-disk13s3")
        try FileManager.default.createDirectory(at: firstMountPoint, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondMountPoint, withIntermediateDirectories: true)

        let firstVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s2",
            volumeName: "HP_NTFS_A",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: firstMountPoint.path,
            isMounted: true,
            isWritable: true
        )
        let secondVolume = DiskVolume.testVolume(
            deviceIdentifier: "disk13s3",
            volumeName: "HP_NTFS_B",
            filesystemType: "ntfsaccess",
            filesystemName: "NTFS Access",
            mountPoint: secondMountPoint.path,
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volumes: [firstVolume, secondVolume])
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            mountConfiguration: MountConfiguration(mountRoot: temporaryDirectory.path),
            dependencyCheck: Self.readyDependencies,
            mountPathExists: { _ in true },
            managedMountPointIsActive: { _ in true }
        )

        _ = orchestrator.reconcile()
        scanner.volumes = [
            firstVolume.copy(
                volumeName: "HP_NTFS_A_RENAMED",
                mediaName: "HP_NTFS_A_RENAMED",
                mountPoint: firstMountPoint.path,
                isMounted: true,
                isWritable: true
            )
        ]
        scanner.listError = AppError(message: "The data could not be read because it is not in the correct format.")
        scanner.infoErrorsByIdentifier["disk13s3"] = AppError(message: "disk13s3 info timeout")

        let result = orchestrator.reconcile()

        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.managedVolumeCount, 2)
        XCTAssertEqual(result.volumes.count, 2)
        let refreshed = result.volumes.first { $0.deviceIdentifier == "disk13s2" }
        let retained = result.volumes.first { $0.deviceIdentifier == "disk13s3" }
        XCTAssertEqual(refreshed?.volumeName, "HP_NTFS_A_RENAMED")
        XCTAssertEqual(refreshed?.mode, .readWrite)
        XCTAssertEqual(retained?.volumeName, "HP_NTFS_B")
        XCTAssertEqual(retained?.mountPoint, secondMountPoint.path)
        XCTAssertEqual(retained?.mode, .readWrite)
    }

    func testMissingManagedMountPointIsForceRemountedInsteadOfOnlyReportedUnhealthy() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/NTFSAccess-disk4s1",
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountUsingRegisteredPersonality(disk4s1,false)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.reason, "")
    }

    func testRootOnlyManagedMountPointIsForceRemountedInsteadOfOnlyReportedUnhealthy() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryDirectory.path)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let rootOnlyMountPoint = temporaryDirectory.appendingPathComponent("NTFSAccess-disk4s1")
        try FileManager.default.createDirectory(at: rootOnlyMountPoint, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rootOnlyMountPoint.path)

        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: rootOnlyMountPoint.path,
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            mountConfiguration: MountConfiguration(mountRoot: temporaryDirectory.path),
            dependencyCheck: Self.readyDependencies
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountUsingRegisteredPersonality(disk4s1,false)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.reason, "")
    }

    func testCollapsedManagedMountPointIsForceRemountedInsteadOfOnlyReportedUnhealthy() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryDirectory.path)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let collapsedMountPoint = temporaryDirectory.appendingPathComponent("NTFSAccess-disk4s1")
        try FileManager.default.createDirectory(at: collapsedMountPoint, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: collapsedMountPoint.path)

        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: collapsedMountPoint.path,
            isMounted: true,
            isWritable: true
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            mountConfiguration: MountConfiguration(mountRoot: temporaryDirectory.path),
            dependencyCheck: Self.readyDependencies
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["unmount(disk4s1,true)", "mountUsingRegisteredPersonality(disk4s1,false)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/Passport")
    }

    func testRawDevicePermissionDeniedKeepsClearFailureReasonAfterNativeRecoveryFails() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        mounter.mountRegisteredPersonalityError = AppError(
            message: "diskutil mount failed for disk4s1: macOS denied raw disk access to /dev/disk4s1."
        )
        mounter.mountNativeReadOnlyError = AppError(message: "Native mount also denied")
        mounter.mountReadWriteError = AppError(
            message: "Mount failed for disk4s1: macOS denied raw disk access to /dev/disk4s1. Granting admin rights is not enough; the helper must run from an approved filesystem/privileged-helper context."
        )
        mounter.mountReadOnlyError = AppError(
            message: "Mount failed for disk4s1: macOS denied raw disk access to /dev/disk4s1. Granting admin rights is not enough; the helper must run from an approved filesystem/privileged-helper context."
        )
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(result.health, .error)
        XCTAssertTrue(result.lastError.contains("macOS denied raw disk access"))
        XCTAssertTrue(result.volumes.first?.reason.contains("macOS denied raw disk access") == true)
    }

    func testUnmountedVolumeRestoresNativeReadOnlyWhenRawDeviceDeniedDuringMount() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let rawDenied = AppError(
            message: "Mount failed for disk4s1: macOS denied raw disk access to /dev/disk4s1."
        )
        mounter.mountRegisteredPersonalityError = rawDenied
        mounter.mountReadWriteError = rawDenied
        mounter.mountReadOnlyError = rawDenied
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, [
            "mountUsingRegisteredPersonality(disk4s1,false)",
            "mountReadWrite(disk4s1)",
            "mountReadOnly(disk4s1)",
            "mountNativeReadOnly(disk4s1)"
        ])
        XCTAssertEqual(result.health, .degradedReadOnly)
        XCTAssertEqual(result.volumes.first?.mode, .readOnly)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/Passport")
        XCTAssertTrue(result.volumes.first?.reason.contains("macOS denied raw disk access") == true)
        XCTAssertTrue(result.volumes.first?.reason.localizedCaseInsensitiveContains("restored native macOS read-only") == true)
    }

    func testReadOnlyFallbackKeepsDetailedPreviousFailureReasonOnLaterScans() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = FakeMounter(scanner: scanner)
        let rawDenied = AppError(message: "Mount failed for disk4s1: macOS denied raw disk access to /dev/disk4s1.")
        mounter.mountRegisteredPersonalityError = rawDenied
        mounter.mountReadWriteError = rawDenied
        mounter.mountReadOnlyError = rawDenied
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        let firstResult = orchestrator.reconcile()
        let secondResult = orchestrator.reconcile()

        XCTAssertEqual(firstResult.health, .degradedReadOnly)
        XCTAssertEqual(secondResult.health, .degradedReadOnly)
        XCTAssertEqual(secondResult.volumes.first?.mode, .readOnly)
        XCTAssertTrue(secondResult.volumes.first?.reason.contains("macOS denied raw disk access") == true)
    }

    func testUnmountedVolumeRestoresNativeReadOnlyWhenWriteProbeIsDeniedByMacOS() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(
            safeForWrite: false,
            reason: "Error opening '/dev/disk4s1': Operation not permitted"
        ))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["mountNativeReadOnly(disk4s1)"])
        XCTAssertEqual(result.health, .degradedReadOnly)
        XCTAssertEqual(result.volumes.first?.mode, .readOnly)
        XCTAssertEqual(result.volumes.first?.mountPoint, "/Volumes/Passport")
        XCTAssertTrue(result.volumes.first?.reason.contains("raw disk access") == true)
    }

    func testUnmountedVolumeFallsBackReadOnlyWhenWriteSafetyProbeIsUnavailable() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(
            safeForWrite: false,
            reason: "ntfs-3g.probe not available; refusing writable mount without safety check"
        ))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["mountReadOnly(disk4s1)"])
        XCTAssertEqual(result.health, .degradedReadOnly)
        XCTAssertEqual(result.volumes.first?.mode, .readOnly)
        XCTAssertEqual(result.volumes.first?.reason, "ntfs-3g.probe not available; refusing writable mount without safety check")
    }

    func testUnmountedVolumeUsesRegisteredFilesystemPersonalityWhenRawWriteProbeIsDenied() {
        let initialVolume = DiskVolume.testVolume(
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false
        )
        let scanner = FakeDiskScanner(volume: initialVolume)
        let probe = FakeProbe(result: ProbeResult(
            safeForWrite: false,
            reason: "Error opening '/dev/disk4s1': Operation not permitted"
        ))
        let mounter = FakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )

        let result = orchestrator.reconcile()

        XCTAssertEqual(mounter.calls, ["mountUsingRegisteredPersonality(disk4s1,false)"])
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.volumes.first?.mode, .readWrite)
    }

    private static func readyDependencies() -> DependencyReport {
        DependencyReport(
            operatingSystem: "test",
            architecture: "arm64",
            ntfs3gPath: "/tmp/ntfs-3g",
            ntfs3gProbePath: "/tmp/ntfs-3g.probe",
            mkntfsPath: "/tmp/mkntfs",
            ntfsfixPath: "/tmp/ntfsfix",
            ntfslabelPath: "/tmp/ntfslabel",
            macFUSEHelperPath: "/tmp/mount_macfuse",
            formatterBundlePath: "/Library/Filesystems/ntfsaccess.fs",
            formatterBundleInstalled: true,
            formatterPersonalityRegistered: true,
            formatterProbeOrders: ["Windows_NTFS": 500],
            ntfsFormatterPersonalityName: "NTFS Access",
            detectedNTFSPersonalities: ["NTFS Access"],
            installedAppSignatureDescription: "signed",
            runningMountDaemonProgram: "/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp",
            runningMountDaemonSignatureDescription: "signed",
            installedMountWrapperUsesAppHelper: true,
            mountIssues: [],
            formatIssues: [],
            advisoryNotes: []
        )
    }

    private static func dependenciesWithoutRegisteredFormatter() -> DependencyReport {
        DependencyReport(
            operatingSystem: "test",
            architecture: "arm64",
            ntfs3gPath: "/tmp/ntfs-3g",
            ntfs3gProbePath: "/tmp/ntfs-3g.probe",
            mkntfsPath: "/tmp/mkntfs",
            ntfsfixPath: "/tmp/ntfsfix",
            ntfslabelPath: "/tmp/ntfslabel",
            macFUSEHelperPath: "/tmp/mount_macfuse",
            formatterBundlePath: "/Library/Filesystems/ntfsaccess.fs",
            formatterBundleInstalled: false,
            formatterPersonalityRegistered: false,
            formatterProbeOrders: [:],
            ntfsFormatterPersonalityName: "NTFS Access",
            detectedNTFSPersonalities: [],
            installedAppSignatureDescription: "signed",
            runningMountDaemonProgram: "/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp",
            runningMountDaemonSignatureDescription: "signed",
            installedMountWrapperUsesAppHelper: true,
            mountIssues: [],
            formatIssues: [],
            advisoryNotes: []
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsaccess-orchestrator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func successfulWriteProbe(_ mountPoint: String, _ user: ConsoleUser) -> Result<Void, Error> {
        .success(())
    }
}

private final class FakeDiskScanner: DiskScanning {
    var volume: DiskVolume {
        get { volumes[0] }
        set {
            if let index = volumes.firstIndex(where: { $0.deviceIdentifier == newValue.deviceIdentifier }) {
                volumes[index] = newValue
            } else {
                volumes = [newValue]
            }
        }
    }
    var volumes: [DiskVolume]
    var listError: Error?
    var infoError: Error?
    var infoErrorAfterUnmount: Error?
    var infoErrorAfterWritableMount: Error?
    var infoErrorsByIdentifier: [String: Error] = [:]

    init(volume: DiskVolume) {
        self.volumes = [volume]
    }

    init(volumes: [DiskVolume]) {
        self.volumes = volumes
    }

    func listNTFSVolumes(externalOnly: Bool) throws -> [DiskVolume] {
        if let listError {
            throw listError
        }
        return volumes
    }

    func info(for deviceIdentifier: String) throws -> DiskVolume {
        if let error = infoErrorsByIdentifier[deviceIdentifier] {
            throw error
        }
        if let infoErrorAfterUnmount,
           let volume = volumes.first(where: { $0.deviceIdentifier == deviceIdentifier }) ?? volumes.first,
           !volume.isMounted {
            throw infoErrorAfterUnmount
        }
        if let infoErrorAfterWritableMount,
           let volume = volumes.first(where: { $0.deviceIdentifier == deviceIdentifier }) ?? volumes.first,
           volume.isMounted,
           volume.isWritable {
            throw infoErrorAfterWritableMount
        }
        if let infoError {
            throw infoError
        }
        return volumes.first { $0.deviceIdentifier == deviceIdentifier } ?? volume
    }
}

private final class FakeProbe: WriteSafetyProbing {
    let result: ProbeResult

    init(result: ProbeResult) {
        self.result = result
    }

    func checkWriteSafety(deviceNode: String) -> ProbeResult {
        result
    }
}

private final class FakeMounter: VolumeMounting {
    var calls: [String] = []
    var rawDeviceReadable = true
    private(set) var rawReadCheckCount = 0
    var mountReadWriteError: Error?
    var mountReadOnlyError: Error?
    var mountNativeReadOnlyError: Error?
    var mountRegisteredPersonalityError: Error?
    var registeredPersonalityMountsReadOnly = false
    var registeredPersonalityMountPointOverride: String?
    private let scanner: FakeDiskScanner

    init(scanner: FakeDiskScanner) {
        self.scanner = scanner
    }

    func mountReadWrite(volume: DiskVolume, user: ConsoleUser) throws -> String {
        calls.append("mountReadWrite(\(volume.deviceIdentifier))")
        if let mountReadWriteError {
            throw mountReadWriteError
        }
        let mountPoint = MountConfiguration().mountPoint(for: volume)
        scanner.volume = volume.copy(mountPoint: mountPoint, isMounted: true, isWritable: true)
        return mountPoint
    }

    func mountReadOnly(volume: DiskVolume, user: ConsoleUser) throws -> String {
        calls.append("mountReadOnly(\(volume.deviceIdentifier))")
        if let mountReadOnlyError {
            throw mountReadOnlyError
        }
        let mountPoint = MountConfiguration().mountPoint(for: volume)
        scanner.volume = volume.copy(mountPoint: mountPoint, isMounted: true, isWritable: false)
        return mountPoint
    }

    func unmount(deviceIdentifier: String, mountPoint: String?, force: Bool) throws {
        calls.append("unmount(\(deviceIdentifier),\(force))")
        let volume = scanner.volumes.first { $0.deviceIdentifier == deviceIdentifier } ?? scanner.volume
        scanner.volume = volume.copy(mountPoint: nil, isMounted: false, isWritable: false)
    }

    func mountNativeReadOnly(deviceIdentifier: String) throws {
        calls.append("mountNativeReadOnly(\(deviceIdentifier))")
        if let mountNativeReadOnlyError {
            throw mountNativeReadOnlyError
        }
        let volume = scanner.volumes.first { $0.deviceIdentifier == deviceIdentifier } ?? scanner.volume
        scanner.volume = volume.copy(mountPoint: "/Volumes/\(volume.volumeName)", isMounted: true, isWritable: false)
    }

    func mountUsingRegisteredPersonality(deviceIdentifier: String, readOnly: Bool) throws {
        calls.append("mountUsingRegisteredPersonality(\(deviceIdentifier),\(readOnly))")
        if let mountRegisteredPersonalityError {
            throw mountRegisteredPersonalityError
        }
        let volume = scanner.volumes.first { $0.deviceIdentifier == deviceIdentifier } ?? scanner.volume
        scanner.volume = volume.copy(
            mountPoint: registeredPersonalityMountPointOverride ?? "/Volumes/\(volume.volumeName)",
            isMounted: true,
            isWritable: !readOnly && !registeredPersonalityMountsReadOnly
        )
    }

    func canReadRawDevice(_ deviceNode: String) -> Bool {
        rawReadCheckCount += 1
        return rawDeviceReadable
    }
}

private extension DiskVolume {
    static func testVolume(
        deviceIdentifier: String = "disk4s1",
        volumeUUID: String? = nil,
        diskUUID: String? = nil,
        mediaUUID: String? = nil,
        parentWholeDisk: String? = nil,
        parentWholeDiskName: String? = nil,
        partitionMapPartitionOffset: Int64? = nil,
        size: Int64? = nil,
        volumeName: String = "Passport",
        filesystemType: String?,
        filesystemName: String?,
        mountPoint: String?,
        isMounted: Bool,
        isWritable: Bool
    ) -> DiskVolume {
        DiskVolume(
            deviceIdentifier: deviceIdentifier,
            deviceNode: "/dev/\(deviceIdentifier)",
            volumeUUID: volumeUUID,
            diskUUID: diskUUID,
            mediaUUID: mediaUUID,
            parentWholeDisk: parentWholeDisk,
            parentWholeDiskName: parentWholeDiskName,
            partitionMapPartitionOffset: partitionMapPartitionOffset,
            size: size,
            volumeName: volumeName,
            mediaName: volumeName,
            filesystemType: filesystemType,
            filesystemName: filesystemName,
            mountPoint: mountPoint,
            isMounted: isMounted,
            isWritable: isWritable,
            isInternal: false
        )
    }

    func copy(
        volumeName: String? = nil,
        mediaName: String? = nil,
        filesystemType: String? = nil,
        filesystemName: String? = nil,
        mountPoint: String?,
        isMounted: Bool,
        isWritable: Bool
    ) -> DiskVolume {
        DiskVolume(
            deviceIdentifier: deviceIdentifier,
            deviceNode: deviceNode,
            stableIdentity: stableIdentity,
            volumeUUID: volumeUUID,
            diskUUID: diskUUID,
            mediaUUID: mediaUUID,
            parentWholeDisk: parentWholeDisk,
            parentWholeDiskName: parentWholeDiskName,
            partitionMapPartitionOffset: partitionMapPartitionOffset,
            size: size,
            volumeName: volumeName ?? self.volumeName,
            mediaName: mediaName ?? self.mediaName,
            filesystemType: filesystemType ?? self.filesystemType,
            filesystemName: filesystemName ?? self.filesystemName,
            mountPoint: mountPoint,
            isMounted: isMounted,
            isWritable: isWritable,
            isInternal: isInternal
        )
    }
}
