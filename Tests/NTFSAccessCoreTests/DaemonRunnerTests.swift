@testable import NTFSAccessCore
@testable import NTFSAccessShared
@testable import NTFSMountDaemonCore
import XCTest

final class DaemonRunnerTests: XCTestCase {
    func testScanNowQueuesScanWithoutBlockingStatusPath() {
        let initialVolume = DiskVolume(
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
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)

        runner.scanNow(reason: "test")

        eventually(timeout: 1) {
            !stateStore.currentVolumeStates().isEmpty
        }
        let states = stateStore.currentVolumeStates()
        XCTAssertEqual(states.first?.mode, .readWrite)
        XCTAssertEqual(states.first?.mountPoint, "/Volumes/Passport")
    }

    func testScanNowReturnsQuicklyWhenAnotherScanIsAlreadyRunning() {
        let initialVolume = DiskVolume(
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
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        scanner.listDelay = 0.4
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)

        runner.triggerScan(reason: "slow background")
        Thread.sleep(forTimeInterval: 0.05)

        let start = Date()
        runner.scanNow(reason: "manual while busy")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.2)
    }

    func testScanNowBlockingWaitsForReconcileBeforeReturning() {
        let initialVolume = DiskVolume(
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
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        scanner.listDelay = 0.1
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)

        runner.scanNowBlocking(reason: "test blocking")

        let states = stateStore.currentVolumeStates()
        XCTAssertEqual(states.first?.mode, .readWrite)
        XCTAssertEqual(states.first?.mountPoint, "/Volumes/Passport")
    }

    func testTargetedScanRefreshesOneKnownVolumeWithoutDroppingSibling() {
        let firstVolume = Self.unmountedTestVolume()
        let secondVolume = DiskVolume(
            deviceIdentifier: "disk5s1",
            deviceNode: "/dev/disk5s1",
            volumeName: "Archive",
            mediaName: "Archive",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )
        let scanner = RunnerFakeDiskScanner(volumes: [firstVolume, secondVolume])
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)

        runner.scanNowBlocking(reason: "initial")
        XCTAssertEqual(stateStore.currentVolumeStates().count, 2)
        let listCallsAfterInitialScan = scanner.listCallCount
        scanner.replaceVolume(DiskVolume(
            deviceIdentifier: firstVolume.deviceIdentifier,
            deviceNode: firstVolume.deviceNode,
            stableIdentity: firstVolume.stableIdentity,
            volumeName: "Renamed",
            mediaName: "Renamed",
            filesystemType: firstVolume.filesystemType,
            filesystemName: firstVolume.filesystemName,
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: firstVolume.isInternal
        ))

        runner.scanVolumeBlocking(stableIdentity: firstVolume.stableIdentity, reason: "targeted")

        let states = stateStore.currentVolumeStates()
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states.first { $0.stableIdentity == firstVolume.stableIdentity }?.volumeName, "Renamed")
        XCTAssertEqual(states.first { $0.stableIdentity == secondVolume.stableIdentity }?.volumeName, "Archive")
        XCTAssertEqual(scanner.listCallCount, listCallsAfterInitialScan)
        XCTAssertGreaterThan(scanner.infoCallCount(for: firstVolume.deviceIdentifier), 0)
    }

    func testTargetedScanRemovesKnownStateWhenDirectEvidenceShowsTargetIsNoLongerNTFS() {
        let initialVolume = Self.unmountedTestVolume()
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)

        runner.scanNowBlocking(reason: "initial")
        XCTAssertEqual(stateStore.currentVolumeStates().count, 1)
        scanner.replaceVolume(DiskVolume(
            deviceIdentifier: initialVolume.deviceIdentifier,
            deviceNode: initialVolume.deviceNode,
            stableIdentity: initialVolume.stableIdentity,
            volumeName: "Reformatted",
            mediaName: "Reformatted",
            filesystemType: "apfs",
            filesystemName: "APFS",
            mountPoint: "/Volumes/Reformatted",
            isMounted: true,
            isWritable: true,
            isInternal: false
        ))

        runner.scanVolumeBlocking(stableIdentity: initialVolume.stableIdentity, reason: "targeted")

        XCTAssertTrue(stateStore.currentVolumeStates().isEmpty)
    }

    func testServiceStateShowsScanProgressWhileScanIsRunning() {
        let initialVolume = Self.unmountedTestVolume()
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        scanner.listDelay = 0.25
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)

        runner.triggerScan(reason: "slow test")

        eventually(timeout: 1) {
            stateStore.currentServiceState().operation == .scanning
                && stateStore.currentServiceState().operationMessage.contains("slow test")
        }
        eventually(timeout: 1) {
            stateStore.currentServiceState().operation == .idle
                && stateStore.currentVolumeStates().first?.mode == .readWrite
        }
    }

    func testXPCScanNowReplyQueuesFreshScanWithoutWaitingForDiskutil() throws {
        let initialVolume = Self.unmountedTestVolume()
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        scanner.listDelay = 0.3
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)
        let settingsURL = try makeTemporaryDirectory().appendingPathComponent("settings.plist")
        let service = MountdXPCService(
            stateStore: stateStore,
            runner: runner,
            settingsStore: DaemonSettingsStore(fileURL: settingsURL),
            orchestrator: orchestrator,
            authorizer: AllowAllAuthorizer(),
            rateLimiter: XPCMutationRateLimiter(minimumInterval: 0)
        )
        let replyReceived = expectation(description: "scan-now reply")
        let start = Date()

        service.scanNow { result in
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.message, "scan queued")
            replyReceived.fulfill()
        }

        wait(for: [replyReceived], timeout: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)

        eventually(timeout: 1) {
            !stateStore.currentVolumeStates().isEmpty
        }
        let states = stateStore.currentVolumeStates()
        XCTAssertEqual(states.first?.mode, .readWrite)
        XCTAssertEqual(states.first?.mountPoint, "/Volumes/Passport")
    }

    func testXPCScanNowBlockingWaitsForFreshScanBeforeReplying() throws {
        let initialVolume = Self.unmountedTestVolume()
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        scanner.listDelay = 0.1
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)
        let settingsURL = try makeTemporaryDirectory().appendingPathComponent("settings.plist")
        let service = MountdXPCService(
            stateStore: stateStore,
            runner: runner,
            settingsStore: DaemonSettingsStore(fileURL: settingsURL),
            orchestrator: orchestrator,
            authorizer: AllowAllAuthorizer(),
            rateLimiter: XPCMutationRateLimiter(minimumInterval: 0)
        )
        let replyReceived = expectation(description: "blocking scan-now reply")

        service.scanNowBlocking { result in
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.message, "scan completed")
            XCTAssertEqual(stateStore.currentVolumeStates().first?.mode, .readWrite)
            replyReceived.fulfill()
        }

        wait(for: [replyReceived], timeout: 1)
    }

    func testXPCReadOnlyStateCallsBypassMutatingAuthorization() throws {
        let fixture = try makeServiceFixture(authorizer: DenyAllAuthorizer())
        let session = fixture.service.sessionForTesting(identity: XPCClientIdentity(uid: 2500, gid: 20, pid: 123))
        let stateReply = expectation(description: "state reply")
        let volumesReply = expectation(description: "volume reply")

        session.getServiceState { state in
            XCTAssertEqual(state.lastError, "service starting")
            stateReply.fulfill()
        }
        session.getVolumeStates { states in
            XCTAssertEqual(states.count, 0)
            volumesReply.fulfill()
        }

        wait(for: [stateReply, volumesReply], timeout: 1)
    }

    func testXPCDeniedMutatingCallsDoNotScanRetryOrPersistSettings() throws {
        let fixture = try makeServiceFixture(authorizer: DenyAllAuthorizer())
        let session = fixture.service.sessionForTesting(identity: XPCClientIdentity(uid: 2500, gid: 20, pid: 123))

        let scanResult = waitForOperation { session.scanNow($0) }
        let blockingScanResult = waitForOperation { session.scanNowBlocking($0) }
        let retryResult = waitForOperation { session.retryMounts($0) }
        let blockingRetryResult = waitForOperation { session.retryMountsBlocking($0) }
        let notificationsResult = waitForOperation { session.setNotificationsEnabled(false, reply: $0) }
        let durabilityResult = waitForOperation { session.setDurabilityMode(MountDurabilityMode.conservative.rawValue, reply: $0) }

        for result in [scanResult, blockingScanResult, retryResult, blockingRetryResult, notificationsResult, durabilityResult] {
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.message.contains("Not authorized"), result.message)
        }
        XCTAssertEqual(fixture.scanner.listCallCount, 0)
        XCTAssertEqual(fixture.settingsStore.load().notificationsEnabled, true)
        XCTAssertEqual(fixture.settingsStore.load().durabilityMode, .performance)
        XCTAssertEqual(fixture.stateStore.currentServiceState().notificationsEnabled, true)
        XCTAssertEqual(fixture.stateStore.currentServiceState().durabilityMode, .performance)
    }

    func testXPCDeniedRepairVolumeDoesNotScanOrMutate() throws {
        let fixture = try makeServiceFixture(authorizer: DenyAllAuthorizer())
        let session = fixture.service.sessionForTesting(identity: XPCClientIdentity(uid: 2500, gid: 20, pid: 123))

        let result = waitForOperation {
            session.repairVolume(
                stableIdentity: "disk4s1",
                actionRawValue: VolumeRecoveryActionRaw.retryMount.rawValue,
                reply: $0
            )
        }

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("Not authorized"), result.message)
        XCTAssertEqual(fixture.scanner.listCallCount, 0)
    }

    func testXPCRepairGuidanceOnlyActionsDoNotScan() throws {
        let fixture = try makeServiceFixture()
        let session = fixture.service.sessionForTesting(identity: XPCClientIdentity(uid: 501, gid: 20, pid: 123))

        let unsafeResult = waitForOperation {
            session.repairVolume(
                stableIdentity: "disk4s1",
                actionRawValue: VolumeRecoveryActionRaw.showWindowsCleanupGuidance.rawValue,
                reply: $0
            )
        }
        let macFUSEResult = waitForOperation {
            session.repairVolume(
                stableIdentity: "disk4s1",
                actionRawValue: VolumeRecoveryActionRaw.showMacFUSEGuidance.rawValue,
                reply: $0
            )
        }

        XCTAssertTrue(unsafeResult.success, unsafeResult.message)
        XCTAssertTrue(unsafeResult.message.localizedCaseInsensitiveContains("Windows"), unsafeResult.message)
        XCTAssertTrue(macFUSEResult.success, macFUSEResult.message)
        XCTAssertTrue(macFUSEResult.message.localizedCaseInsensitiveContains("macFUSE"), macFUSEResult.message)
        XCTAssertEqual(fixture.scanner.listCallCount, 0)
    }

    func testXPCRepairRetryActionClearsBackoffAndCompletesTargetedScan() throws {
        let initialVolume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false,
            isInternal: false
        )
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        scanner.listDelay = 0.25
        scanner.infoDelay = 0.25
        let probe = RunnerFakeProbe(result: ProbeResult(
            safeForWrite: false,
            reason: "Error opening '/dev/disk4s1': Operation not permitted"
        ))
        let mounter = RunnerFakeMounter(scanner: scanner)
        mounter.rawDeviceReadable = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter,
            nativeReadOnlyTakeoverRetryInterval: 3600,
            rawAccessReadinessCheckInterval: 3600
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)
        let settingsURL = try makeTemporaryDirectory().appendingPathComponent("settings.plist")
        let service = MountdXPCService(
            stateStore: stateStore,
            runner: runner,
            settingsStore: DaemonSettingsStore(fileURL: settingsURL),
            orchestrator: orchestrator,
            authorizer: AllowAllAuthorizer(),
            rateLimiter: XPCMutationRateLimiter(minimumInterval: 0)
        )
        service.scanNowBlocking { _ in }
        XCTAssertEqual(stateStore.currentVolumeStates().first?.presentationState, .nativeReadOnly)

        probe.result = ProbeResult(safeForWrite: true, reason: "write probe passed")
        mounter.rawDeviceReadable = true
        let session = service.sessionForTesting(identity: XPCClientIdentity(uid: 501, gid: 20, pid: 123))
        let replyReceived = expectation(description: "repair retry reply")
        let start = Date()

        session.repairVolume(
            stableIdentity: initialVolume.stableIdentity,
            actionRawValue: VolumeRecoveryActionRaw.retryWritableTakeover.rawValue
        ) { result in
            XCTAssertTrue(result.success, result.message)
            XCTAssertEqual(result.message, "repair completed")
            replyReceived.fulfill()
        }

        wait(for: [replyReceived], timeout: 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.24)
        XCTAssertEqual(stateStore.currentVolumeStates().first?.mode, .readWrite)
    }

    func testXPCRepairRejectsNonActionableGreenState() throws {
        let fixture = try makeServiceFixture()
        fixture.service.scanNowBlocking { _ in }
        XCTAssertEqual(fixture.stateStore.currentVolumeStates().first?.presentationState, .readWriteVerified)
        let session = fixture.service.sessionForTesting(identity: XPCClientIdentity(uid: 501, gid: 20, pid: 123))

        let result = waitForOperation {
            session.repairVolume(
                stableIdentity: fixture.scanner.volume.stableIdentity,
                actionRawValue: VolumeRecoveryActionRaw.retryMount.rawValue,
                reply: $0
            )
        }

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("not actionable"), result.message)
    }

    func testXPCEjectVolumeUnmountsPartitionAndKeepsItUnmountedUntilRetry() throws {
        let fixture = try makeServiceFixture()
        fixture.service.scanNowBlocking { _ in }
        let initialState = try XCTUnwrap(fixture.stateStore.currentVolumeStates().first)
        XCTAssertEqual(initialState.mode, .readWrite)
        let session = fixture.service.sessionForTesting(identity: XPCClientIdentity(uid: 501, gid: 20, pid: 123))

        let ejectResult = waitForOperation {
            session.ejectVolume(stableIdentity: initialState.stableIdentity, reply: $0)
        }

        XCTAssertTrue(ejectResult.success, ejectResult.message)
        XCTAssertTrue(ejectResult.message.contains("ejected"), ejectResult.message)
        eventually(timeout: 1) {
            fixture.stateStore.currentVolumeStates().first?.mode == .unmounted
        }
        XCTAssertEqual(fixture.mounter.unmountCallCount, 1)

        let scanResult = waitForOperation { session.scanNowBlocking($0) }
        XCTAssertTrue(scanResult.success, scanResult.message)
        XCTAssertEqual(fixture.stateStore.currentVolumeStates().first?.mode, .unmounted)
        XCTAssertEqual(fixture.mounter.unmountCallCount, 1)

        let retryResult = waitForOperation { session.retryMountsBlocking($0) }
        XCTAssertTrue(retryResult.success, retryResult.message)
        XCTAssertEqual(fixture.stateStore.currentVolumeStates().first?.mode, .readWrite)
    }

    func testXPCRepairRetryMountWaitsForTargetedScanAndClearsEjectedState() throws {
        let fixture = try makeServiceFixture()
        fixture.service.scanNowBlocking { _ in }
        let initialState = try XCTUnwrap(fixture.stateStore.currentVolumeStates().first)
        let session = fixture.service.sessionForTesting(identity: XPCClientIdentity(uid: 501, gid: 20, pid: 123))

        let ejectResult = waitForOperation {
            session.ejectVolume(stableIdentity: initialState.stableIdentity, reply: $0)
        }
        XCTAssertTrue(ejectResult.success, ejectResult.message)
        eventually(timeout: 1) {
            fixture.stateStore.currentVolumeStates().first?.mode == .unmounted
        }

        fixture.scanner.infoDelay = 0.2
        let start = Date()
        let repairResult = waitForOperation {
            session.repairVolume(
                stableIdentity: initialState.stableIdentity,
                actionRawValue: VolumeRecoveryActionRaw.retryMount.rawValue,
                reply: $0
            )
        }

        XCTAssertTrue(repairResult.success, repairResult.message)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.18)
        let repairedState = try XCTUnwrap(fixture.stateStore.currentVolumeStates().first)
        XCTAssertEqual(repairedState.mode, .readWrite)
        XCTAssertFalse(repairedState.reason.localizedCaseInsensitiveContains("user ejected"))
    }

    func testXPCAllowedMutatingCallsPreserveExistingBehavior() throws {
        let fixture = try makeServiceFixture()
        let session = fixture.service.sessionForTesting(identity: XPCClientIdentity(uid: 501, gid: 20, pid: 123))

        let scanResult = waitForOperation { session.scanNow($0) }
        XCTAssertTrue(scanResult.success, scanResult.message)
        eventually(timeout: 1) {
            fixture.stateStore.currentVolumeStates().first?.mode == .readWrite
        }

        fixture.scanner.volume = Self.unmountedTestVolume()
        let blockingScanResult = waitForOperation { session.scanNowBlocking($0) }
        XCTAssertTrue(blockingScanResult.success, blockingScanResult.message)
        XCTAssertEqual(fixture.stateStore.currentVolumeStates().first?.mode, .readWrite)

        let notificationsResult = waitForOperation { session.setNotificationsEnabled(false, reply: $0) }
        XCTAssertTrue(notificationsResult.success, notificationsResult.message)
        XCTAssertFalse(fixture.settingsStore.load().notificationsEnabled)
        XCTAssertFalse(fixture.stateStore.currentServiceState().notificationsEnabled)

        let durabilityResult = waitForOperation { session.setDurabilityMode(MountDurabilityMode.conservative.rawValue, reply: $0) }
        XCTAssertTrue(durabilityResult.success, durabilityResult.message)
        XCTAssertEqual(fixture.settingsStore.load().durabilityMode, .conservative)
        XCTAssertEqual(fixture.stateStore.currentServiceState().durabilityMode, .conservative)
    }

    func testXPCRateLimitsScanAndRetryBurstsPerUser() throws {
        let limiter = XPCMutationRateLimiter(minimumInterval: 30)
        let fixture = try makeServiceFixture(rateLimiter: limiter)
        let session = fixture.service.sessionForTesting(identity: XPCClientIdentity(uid: 501, gid: 20, pid: 123))

        let firstScan = waitForOperation { session.scanNowBlocking($0) }
        let secondScan = waitForOperation { session.scanNowBlocking($0) }
        XCTAssertTrue(firstScan.success, firstScan.message)
        XCTAssertFalse(secondScan.success)
        XCTAssertTrue(secondScan.message.contains("Rate limited"), secondScan.message)

        fixture.probe.result = ProbeResult(
            safeForWrite: false,
            reason: "Error opening '/dev/disk4s1': Operation not permitted"
        )
        fixture.mounter.rawDeviceReadable = false
        let firstRetry = waitForOperation { session.retryMounts($0) }
        let secondRetry = waitForOperation { session.retryMounts($0) }
        XCTAssertTrue(firstRetry.success, firstRetry.message)
        XCTAssertFalse(secondRetry.success)
        XCTAssertTrue(secondRetry.message.contains("Rate limited"), secondRetry.message)
    }

    func testMutatingXPCAuthorizerAllowsRootConsoleOrAdminAndDeniesOtherUsers() {
        let authorizer = MutatingXPCAuthorizer(
            consoleUserProvider: { ConsoleUser(uid: 501, gid: 20) },
            isAdminProvider: { $0.uid == 777 }
        )

        XCTAssertTrue(authorizer.authorization(for: .scanNow, client: XPCClientIdentity(uid: 0, gid: 0)).allowed)
        XCTAssertTrue(authorizer.authorization(for: .retryMounts, client: XPCClientIdentity(uid: 501, gid: 20)).allowed)
        XCTAssertTrue(authorizer.authorization(for: .setDurabilityMode, client: XPCClientIdentity(uid: 777, gid: 20)).allowed)

        let denied = authorizer.authorization(for: .scanNowBlocking, client: XPCClientIdentity(uid: 2500, gid: 20))
        XCTAssertFalse(denied.allowed)
        XCTAssertTrue(denied.reason.contains("signed-in console user"), denied.reason)
    }

    func testXPCRetryMountsClearsRawAccessBackoffAndQueuesFreshScanWithoutWaiting() throws {
        let initialVolume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false,
            isInternal: false
        )
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        scanner.listDelay = 0.25
        let probe = RunnerFakeProbe(result: ProbeResult(
            safeForWrite: false,
            reason: "Error opening '/dev/disk4s1': Operation not permitted"
        ))
        let mounter = RunnerFakeMounter(scanner: scanner)
        mounter.rawDeviceReadable = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter,
            nativeReadOnlyTakeoverRetryInterval: 3600,
            rawAccessReadinessCheckInterval: 3600
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)
        let settingsURL = try makeTemporaryDirectory().appendingPathComponent("settings.plist")
        let service = MountdXPCService(
            stateStore: stateStore,
            runner: runner,
            settingsStore: DaemonSettingsStore(fileURL: settingsURL),
            orchestrator: orchestrator,
            authorizer: AllowAllAuthorizer(),
            rateLimiter: XPCMutationRateLimiter(minimumInterval: 0)
        )
        service.scanNowBlocking { _ in }
        XCTAssertEqual(stateStore.currentVolumeStates().first?.mode, .readOnly)

        probe.result = ProbeResult(safeForWrite: true, reason: "write probe passed")
        mounter.rawDeviceReadable = true
        let replyReceived = expectation(description: "retry-mounts reply")
        let start = Date()

        service.retryMounts { result in
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.message, "retry queued")
            replyReceived.fulfill()
        }

        wait(for: [replyReceived], timeout: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        eventually(timeout: 1) {
            stateStore.currentVolumeStates().first?.mode == .readWrite
        }
    }

    func testXPCRetryMountsBlockingClearsRawAccessBackoffAndWaitsForFreshScan() throws {
        let initialVolume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/Passport",
            isMounted: true,
            isWritable: false,
            isInternal: false
        )
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        let probe = RunnerFakeProbe(result: ProbeResult(
            safeForWrite: false,
            reason: "Error opening '/dev/disk4s1': Operation not permitted"
        ))
        let mounter = RunnerFakeMounter(scanner: scanner)
        mounter.rawDeviceReadable = false
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.dependenciesWithoutRegisteredFormatter,
            nativeReadOnlyTakeoverRetryInterval: 3600,
            rawAccessReadinessCheckInterval: 3600
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)
        let settingsURL = try makeTemporaryDirectory().appendingPathComponent("settings.plist")
        let service = MountdXPCService(
            stateStore: stateStore,
            runner: runner,
            settingsStore: DaemonSettingsStore(fileURL: settingsURL),
            orchestrator: orchestrator,
            authorizer: AllowAllAuthorizer(),
            rateLimiter: XPCMutationRateLimiter(minimumInterval: 0)
        )

        service.scanNowBlocking { _ in }
        XCTAssertEqual(stateStore.currentVolumeStates().first?.mode, .readOnly)

        probe.result = ProbeResult(safeForWrite: true, reason: "write probe passed")
        mounter.rawDeviceReadable = true
        let replyReceived = expectation(description: "retry-mounts reply")

        service.retryMountsBlocking { result in
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.message, "retry completed")
            XCTAssertEqual(stateStore.currentVolumeStates().first?.mode, .readWrite)
            replyReceived.fulfill()
        }

        wait(for: [replyReceived], timeout: 1)
    }

    func testBurstScanRequestsCoalesceWhileScanIsRunning() {
        let initialVolume = DiskVolume(
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
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        scanner.listDelay = 0.01
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)

        for index in 0..<20 {
            runner.triggerScan(reason: "burst-\(index)")
        }
        runner.scanNowBlocking(reason: "flush")

        XCTAssertLessThanOrEqual(scanner.listCallCount, 2)
        XCTAssertEqual(stateStore.currentVolumeStates().first?.mode, .readWrite)
    }

    func testBurstDiskDisappearedEventsCoalesceWhileScanIsRunning() {
        let initialVolume = DiskVolume(
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
        let scanner = RunnerFakeDiskScanner(volume: initialVolume)
        scanner.listDelay = 0.01
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)

        for _ in 0..<20 {
            runner.handleDiskDisappeared()
        }
        runner.scanNowBlocking(reason: "flush disappeared events")

        XCTAssertLessThanOrEqual(scanner.listCallCount, 2)
        XCTAssertEqual(stateStore.currentVolumeStates().first?.mode, .readWrite)
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

    private func eventually(timeout: TimeInterval, predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(predicate())
    }

    private static func successfulWriteProbe(_ mountPoint: String, _ user: ConsoleUser) -> Result<Void, Error> {
        .success(())
    }

    private static func unmountedTestVolume() -> DiskVolume {
        DiskVolume(
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
    }

    private func makeServiceFixture(
        authorizer: XPCMutatingAuthorizing = AllowAllAuthorizer(),
        rateLimiter: XPCMutationRateLimiting = XPCMutationRateLimiter(minimumInterval: 0)
    ) throws -> ServiceFixture {
        let scanner = RunnerFakeDiskScanner(volume: Self.unmountedTestVolume())
        let probe = RunnerFakeProbe(result: ProbeResult(safeForWrite: true, reason: "safe"))
        let mounter = RunnerFakeMounter(scanner: scanner)
        let orchestrator = NTFSOrchestrator(
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            mountPointWriteProbe: Self.successfulWriteProbe,
            dependencyCheck: Self.readyDependencies
        )
        let stateStore = DaemonStateStore()
        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore)
        let settingsURL = try makeTemporaryDirectory().appendingPathComponent("settings.plist")
        let settingsStore = DaemonSettingsStore(fileURL: settingsURL)
        let service = MountdXPCService(
            stateStore: stateStore,
            runner: runner,
            settingsStore: settingsStore,
            orchestrator: orchestrator,
            authorizer: authorizer,
            rateLimiter: rateLimiter
        )

        return ServiceFixture(
            service: service,
            scanner: scanner,
            probe: probe,
            mounter: mounter,
            stateStore: stateStore,
            settingsStore: settingsStore
        )
    }

    private func waitForOperation(
        _ invoke: (@escaping (OperationResultDTO) -> Void) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> OperationResultDTO {
        let expectation = expectation(description: "operation reply")
        var output: OperationResultDTO?

        invoke { result in
            output = result
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        return output ?? OperationResultDTO(success: false, message: "missing reply")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsaccess-daemon-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct ServiceFixture {
    let service: MountdXPCService
    let scanner: RunnerFakeDiskScanner
    let probe: RunnerFakeProbe
    let mounter: RunnerFakeMounter
    let stateStore: DaemonStateStore
    let settingsStore: DaemonSettingsStore
}

private struct AllowAllAuthorizer: XPCMutatingAuthorizing {
    func authorization(for mutation: XPCMutation, client: XPCClientIdentity) -> XPCMutationAuthorization {
        .allowed
    }
}

private struct DenyAllAuthorizer: XPCMutatingAuthorizing {
    func authorization(for mutation: XPCMutation, client: XPCClientIdentity) -> XPCMutationAuthorization {
        XPCMutationAuthorization(allowed: false, reason: "test denied")
    }
}

private final class RunnerFakeDiskScanner: DiskScanning {
    var volume: DiskVolume
    var listDelay: TimeInterval = 0
    var infoDelay: TimeInterval = 0
    private(set) var listCallCount = 0
    private var infoCallCounts: [String: Int] = [:]

    init(volume: DiskVolume) {
        self.volume = volume
    }

    init(volumes: [DiskVolume]) {
        self.volume = volumes[0]
        self.volumes = volumes
    }

    private var volumes: [DiskVolume] = []

    func listNTFSVolumes(externalOnly: Bool) throws -> [DiskVolume] {
        listCallCount += 1
        if listDelay > 0 {
            Thread.sleep(forTimeInterval: listDelay)
        }
        if volumes.isEmpty {
            return [volume]
        }
        return volumes
    }

    func info(for deviceIdentifier: String) throws -> DiskVolume {
        infoCallCounts[deviceIdentifier, default: 0] += 1
        if infoDelay > 0 {
            Thread.sleep(forTimeInterval: infoDelay)
        }
        if let matched = volumes.first(where: { $0.deviceIdentifier == deviceIdentifier }) {
            return matched
        }
        return volume
    }

    func replaceVolume(_ newVolume: DiskVolume) {
        volume = newVolume
        if let index = volumes.firstIndex(where: { $0.deviceIdentifier == newVolume.deviceIdentifier }) {
            volumes[index] = newVolume
        } else if !volumes.isEmpty {
            volumes.append(newVolume)
        }
    }

    func infoCallCount(for deviceIdentifier: String) -> Int {
        infoCallCounts[deviceIdentifier, default: 0]
    }
}

private final class RunnerFakeProbe: WriteSafetyProbing {
    var result: ProbeResult

    init(result: ProbeResult) {
        self.result = result
    }

    func checkWriteSafety(deviceNode: String) -> ProbeResult {
        result
    }
}

private final class RunnerFakeMounter: VolumeMounting {
    private let scanner: RunnerFakeDiskScanner
    var rawDeviceReadable = true
    private(set) var unmountCallCount = 0

    init(scanner: RunnerFakeDiskScanner) {
        self.scanner = scanner
    }

    func mountReadWrite(volume: DiskVolume, user: ConsoleUser) throws -> String {
        let mountPoint = "/Volumes/NTFSAccess-\(volume.deviceIdentifier)"
        scanner.volume = DiskVolume(
            deviceIdentifier: volume.deviceIdentifier,
            deviceNode: volume.deviceNode,
            stableIdentity: volume.stableIdentity,
            volumeUUID: volume.volumeUUID,
            diskUUID: volume.diskUUID,
            mediaUUID: volume.mediaUUID,
            parentWholeDisk: volume.parentWholeDisk,
            partitionMapPartitionOffset: volume.partitionMapPartitionOffset,
            size: volume.size,
            volumeName: volume.volumeName,
            mediaName: volume.mediaName,
            filesystemType: volume.filesystemType,
            filesystemName: volume.filesystemName,
            mountPoint: mountPoint,
            isMounted: true,
            isWritable: true,
            isInternal: volume.isInternal
        )
        return mountPoint
    }

    func mountReadOnly(volume: DiskVolume, user: ConsoleUser) throws -> String {
        XCTFail("read-only mount should not be used for a safe writable test volume")
        return ""
    }

    func canReadRawDevice(_ deviceNode: String) -> Bool {
        rawDeviceReadable
    }

    func unmount(deviceIdentifier: String, mountPoint: String?, force: Bool) throws {
        unmountCallCount += 1
        scanner.volume = scanner.volume.copy(mountPoint: nil, isMounted: false, isWritable: false)
    }

    func mountNativeReadOnly(deviceIdentifier: String) throws {
        XCTFail("native read-only mount should not be used for a safe writable test volume")
    }

    func mountUsingRegisteredPersonality(deviceIdentifier: String, readOnly: Bool) throws {
        scanner.volume = scanner.volume.copy(
            mountPoint: "/Volumes/\(scanner.volume.volumeName)",
            isMounted: true,
            isWritable: !readOnly
        )
    }
}

private extension DiskVolume {
    func copy(
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
            partitionMapPartitionOffset: partitionMapPartitionOffset,
            size: size,
            volumeName: volumeName,
            mediaName: mediaName,
            filesystemType: filesystemType,
            filesystemName: filesystemName,
            mountPoint: mountPoint,
            isMounted: isMounted,
            isWritable: isWritable,
            isInternal: isInternal
        )
    }
}
