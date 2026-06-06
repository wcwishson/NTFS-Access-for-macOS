import Darwin
import Foundation
import NTFSAccessShared

public final class NTFSOrchestrator {
    private let scanner: DiskScanning
    private let probe: WriteSafetyProbing
    private let mounter: VolumeMounting?
    private let configuration: DaemonConfiguration
    private let mountConfiguration: MountConfiguration
    private let dependencyCheck: () -> DependencyReport
    private let mountPathExists: (String) -> Bool
    private let managedMountPointIsActive: (String) -> Bool
    private let mountPointWriteProbe: (String, ConsoleUser) -> Result<Void, Error>
    private let now: () -> Date
    private let nativeReadOnlyTakeoverRetryInterval: TimeInterval
    private let rawAccessReadinessCheckInterval: TimeInterval

    private var knownStates: [String: ManagedVolumeState] = [:]
    private var knownDeviceIdentifiersByStableIdentity: [String: String] = [:]
    private var failureCount: [String: Int] = [:]
    private var nextRetryAt: [String: Date] = [:]
    private var nativeReadOnlyFallback: Set<String> = []
    private var nextNativeReadOnlyTakeoverAttemptAt: [String: Date] = [:]
    private var nextRawAccessReadinessCheckAt: [String: Date] = [:]
    private var confirmedWritableNTFSAccessDevices: Set<String> = []
    private var transientManagedMountProbeFailures: Set<String> = []
    private var userEjectedStableIdentities: Set<String> = []

    public init(
        scanner: DiskScanning = DiskScanner(),
        probe: WriteSafetyProbing = NTFSProbe(),
        mounter: VolumeMounting?,
        mountPointWriteProbe: ((String, ConsoleUser) -> Result<Void, Error>)? = nil,
        configuration: DaemonConfiguration = DaemonConfiguration(),
        mountConfiguration: MountConfiguration = MountConfiguration(),
        dependencyCheck: @escaping () -> DependencyReport = { DependencyChecker.run(requireRoot: true) },
        mountPathExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        managedMountPointIsActive: ((String) -> Bool)? = nil,
        now: @escaping () -> Date = Date.init,
        nativeReadOnlyTakeoverRetryInterval: TimeInterval = 300,
        rawAccessReadinessCheckInterval: TimeInterval = 15
    ) {
        self.scanner = scanner
        self.probe = probe
        self.mounter = mounter
        self.configuration = configuration
        self.mountConfiguration = mountConfiguration
        self.dependencyCheck = dependencyCheck
        self.mountPathExists = mountPathExists
        self.managedMountPointIsActive = managedMountPointIsActive ?? NTFSOrchestrator.defaultManagedMountPointIsActive
        self.mountPointWriteProbe = mountPointWriteProbe ?? NTFSOrchestrator.defaultMountPointWriteProbe
        self.now = now
        self.nativeReadOnlyTakeoverRetryInterval = max(0, nativeReadOnlyTakeoverRetryInterval)
        self.rawAccessReadinessCheckInterval = max(0, rawAccessReadinessCheckInterval)
    }

    public func reconcile() -> ReconcileResult {
        let dependencyReport = dependencyCheck()
        if dependencyReport.ntfs3gPath == nil || dependencyReport.macFUSEHelperPath == nil || !dependencyReport.mountReady || mounter == nil {
            let message = dependencyReport.mountIssues.joined(separator: "; ")
            return ReconcileResult(
                volumes: knownStates.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier },
                health: .unavailable,
                lastError: message,
                managedVolumeCount: knownStates.count,
                degradedVolumeCount: knownStates.values.filter { $0.mode == .readOnly }.count
            )
        }

        do {
            let volumes = try scanner.listNTFSVolumes(externalOnly: configuration.manageExternalOnly)
            return reconcile(volumes: volumes)
        } catch {
            if isDiskArbitrationTimeout(error),
               let recoveredResult = recoverCollapsedKnownManagedMountsAfterScanFailure(error, allowLastKnownState: true) {
                return recoveredResult
            }
            if let recoveredResult = recoverKnownVolumesAfterScanFailure(error) {
                return recoveredResult
            }
            if let recoveredResult = recoverCollapsedKnownManagedMountsAfterScanFailure(error, allowLastKnownState: false) {
                return recoveredResult
            }
            if let retainedResult = retainHealthyKnownVolumesAfterTransientScanFailure(error) {
                return retainedResult
            }
            let message = "Scan failed: \(error.localizedDescription)"
            Log.error(message)
            return ReconcileResult(
                volumes: knownStates.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier },
                health: .error,
                lastError: message,
                managedVolumeCount: knownStates.count,
                degradedVolumeCount: knownStates.values.filter { $0.mode == .readOnly }.count
            )
        }
    }

    public func reconcileKnownVolume(stableIdentity: String) -> ReconcileResult {
        let dependencyReport = dependencyCheck()
        if dependencyReport.ntfs3gPath == nil || dependencyReport.macFUSEHelperPath == nil || !dependencyReport.mountReady || mounter == nil {
            let message = dependencyReport.mountIssues.joined(separator: "; ")
            return ReconcileResult(
                volumes: knownStates.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier },
                health: .unavailable,
                lastError: message,
                managedVolumeCount: knownStates.count,
                degradedVolumeCount: knownStates.values.filter { $0.mode == .readOnly }.count
            )
        }

        guard let current = knownStates[stableIdentity] ?? knownStates.values.first(where: { $0.deviceIdentifier == stableIdentity }) else {
            return reconcile()
        }
        let previousStates = knownStates

        do {
            let refreshed = try scanner.info(for: current.deviceIdentifier)
                .mergingPhysicalDriveMetadata(
                    parentWholeDisk: current.parentWholeDisk,
                    parentWholeDiskName: current.parentWholeDiskName
                )
            if refreshed.stableIdentity != current.stableIdentity || !refreshed.isNTFS {
                var mergedStates = previousStates
                mergedStates.removeValue(forKey: current.stableIdentity)
                knownStates = mergedStates
                refreshKnownDeviceIdentifiers()
                pruneTracking(toActiveStableIdentities: Set(mergedStates.keys))
                return reconcileResult(from: mergedStates, lastError: "")
            }

            let refreshedResult = reconcile(
                volumes: [refreshed],
                excludedRetainedStableIdentities: []
            )
            guard previousStates.count > 1 else {
                return refreshedResult
            }

            var mergedStates = previousStates
            for state in refreshedResult.volumes {
                mergedStates[state.stableIdentity] = state
            }
            knownStates = mergedStates
            refreshKnownDeviceIdentifiers()
            pruneTracking(toActiveStableIdentities: Set(mergedStates.keys))
            return reconcileResult(from: mergedStates, lastError: refreshedResult.lastError)
        } catch {
            return ReconcileResult(
                volumes: knownStates.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier },
                health: .error,
                lastError: "Targeted scan failed for \(current.deviceIdentifier): \(error.localizedDescription)",
                managedVolumeCount: knownStates.count,
                degradedVolumeCount: knownStates.values.filter { $0.mode == .readOnly }.count
            )
        }
    }

    public func resetRetryState() {
        failureCount.removeAll()
        nextRetryAt.removeAll()
        nativeReadOnlyFallback.removeAll()
        nextNativeReadOnlyTakeoverAttemptAt.removeAll()
        nextRawAccessReadinessCheckAt.removeAll()
        transientManagedMountProbeFailures.removeAll()
        userEjectedStableIdentities.removeAll()
    }

    public func resetRetryState(for stableIdentity: String) {
        let resolvedIdentity = knownStates[stableIdentity]?.stableIdentity
            ?? knownStates.values.first(where: { $0.deviceIdentifier == stableIdentity })?.stableIdentity
            ?? stableIdentity

        clearBackoff(resolvedIdentity)
        clearNativeReadOnlyFallback(resolvedIdentity)
        confirmedWritableNTFSAccessDevices.remove(resolvedIdentity)
        transientManagedMountProbeFailures.remove(resolvedIdentity)
        userEjectedStableIdentities.remove(resolvedIdentity)
    }

    public func ejectVolume(stableIdentity: String) -> ReconcileResult {
        guard let mounter else {
            return ReconcileResult(
                volumes: knownStates.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier },
                health: .unavailable,
                lastError: "mounter unavailable",
                managedVolumeCount: knownStates.count,
                degradedVolumeCount: knownStates.values.filter { $0.mode == .readOnly }.count
            )
        }
        guard let current = knownStates[stableIdentity] ?? knownStates.values.first(where: { $0.deviceIdentifier == stableIdentity }) else {
            return ReconcileResult(
                volumes: knownStates.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier },
                health: .error,
                lastError: "Volume \(stableIdentity) is not known. Rescan first.",
                managedVolumeCount: knownStates.count,
                degradedVolumeCount: knownStates.values.filter { $0.mode == .readOnly }.count
            )
        }

        do {
            if !current.mountPoint.isEmpty {
                try mounter.unmount(deviceIdentifier: current.deviceIdentifier, mountPoint: current.mountPoint, force: false)
            } else {
                try mounter.unmount(deviceIdentifier: current.deviceIdentifier, mountPoint: nil, force: false)
            }
        } catch {
            let message = "Eject failed for \(current.volumeName): \(error.localizedDescription)"
            var states = knownStates
            states[current.stableIdentity] = ManagedVolumeState(
                deviceIdentifier: current.deviceIdentifier,
                stableIdentity: current.stableIdentity,
                parentWholeDisk: current.parentWholeDisk,
                parentWholeDiskName: current.parentWholeDiskName,
                volumeName: current.volumeName,
                mountPoint: current.mountPoint,
                isExternal: current.isExternal,
                mode: current.mode,
                reason: message,
                lastTransitionAt: Date()
            )
            knownStates = states
            return reconcileResult(from: states, lastError: message)
        }

        userEjectedStableIdentities.insert(current.stableIdentity)
        clearBackoff(current.stableIdentity)
        clearNativeReadOnlyFallback(current.stableIdentity)
        confirmedWritableNTFSAccessDevices.remove(current.stableIdentity)
        transientManagedMountProbeFailures.remove(current.stableIdentity)

        var states = knownStates
        states[current.stableIdentity] = ManagedVolumeState(
            deviceIdentifier: current.deviceIdentifier,
            stableIdentity: current.stableIdentity,
            parentWholeDisk: current.parentWholeDisk,
            parentWholeDiskName: current.parentWholeDiskName,
            volumeName: current.volumeName,
            mountPoint: "",
            isExternal: current.isExternal,
            mode: .unmounted,
            reason: "User ejected this NTFS partition. Click Fix to mount it again.",
            lastTransitionAt: Date()
        )
        knownStates = states
        refreshKnownDeviceIdentifiers()
        return reconcileResult(from: states, lastError: "")
    }

    private func retainHealthyKnownVolumesAfterTransientScanFailure(_ scanError: Error) -> ReconcileResult? {
        guard !knownStates.isEmpty else {
            return nil
        }

        let consoleUser = ConsoleUser.current()
        let collapsedStates = knownStatesWithCollapsedManagedMountsMarked(consoleUser: consoleUser)
        if collapsedStates.values.contains(where: { $0.mode == .unmounted && !$0.reason.isEmpty }) {
            knownStates = collapsedStates
            let volumes = collapsedStates.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier }
            let collapsedState = volumes.first { $0.mode == .unmounted && !$0.reason.isEmpty }
            return ReconcileResult(
                volumes: volumes,
                health: .error,
                lastError: collapsedState?.reason ?? "Managed NTFS mount needs remount",
                managedVolumeCount: collapsedStates.count,
                degradedVolumeCount: collapsedStates.values.filter { $0.mode == .readOnly }.count
            )
        }
        if collapsedStates.values.contains(where: { $0.mode == .readWrite && !$0.reason.isEmpty }) {
            knownStates = collapsedStates
            refreshKnownDeviceIdentifiers()
            return reconcileResult(from: collapsedStates, lastError: "")
        }

        let hasUnhealthyKnownState = knownStates.values.contains { state in
            state.mode != .readWrite || !state.reason.isEmpty
        }
        guard !hasUnhealthyKnownState else {
            return nil
        }

        Log.warning("Global NTFS scan failed; retaining last verified healthy state for \(knownStates.count) known volume(s): \(scanError.localizedDescription)")
        return ReconcileResult(
            volumes: knownStates.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier },
            health: .healthy,
            lastError: "",
            managedVolumeCount: knownStates.count,
            degradedVolumeCount: 0
        )
    }

    private func knownStatesWithCollapsedManagedMountsMarked(consoleUser: ConsoleUser) -> [String: ManagedVolumeState] {
        var updatedStates = knownStates

        for state in knownStates.values where state.mode == .readWrite && isKnownNTFSAccessWritableState(state) {
            if let reason = collapsedManagedMountReason(for: state) {
                if let retainedState = retainedKnownReadWriteStateAfterTransientManagedMountProbeFailure(
                    previous: state,
                    currentVolume: nil,
                    reason: reason,
                    consoleUser: consoleUser
                ) {
                    updatedStates[state.stableIdentity] = retainedState
                    continue
                }
                updatedStates[state.stableIdentity] = ManagedVolumeState(
                    deviceIdentifier: state.deviceIdentifier,
                    stableIdentity: state.stableIdentity,
                    parentWholeDisk: state.parentWholeDisk,
                    parentWholeDiskName: state.parentWholeDiskName,
                    volumeName: state.volumeName,
                    mountPoint: state.mountPoint,
                    isExternal: state.isExternal,
                    mode: .unmounted,
                    reason: reason,
                    lastTransitionAt: Date()
                )
            }
        }

        return updatedStates
    }

    private func recoverCollapsedKnownManagedMountsAfterScanFailure(
        _ scanError: Error,
        allowLastKnownState: Bool
    ) -> ReconcileResult? {
        guard let mounter, !knownStates.isEmpty else {
            return nil
        }

        let consoleUser = ConsoleUser.current()
        var updatedStates = knownStates
        var attemptedRecovery = false
        var lastError = ""

        for state in knownStates.values where state.mode == .readWrite && isKnownNTFSAccessWritableState(state) {
            guard let collapsedReason = collapsedManagedMountReason(for: state) else {
                transientManagedMountProbeFailures.remove(state.stableIdentity)
                continue
            }

            attemptedRecovery = true
            if let retainedState = retainedKnownReadWriteStateAfterTransientManagedMountProbeFailure(
                previous: state,
                currentVolume: nil,
                reason: collapsedReason,
                consoleUser: consoleUser
            ) {
                updatedStates[state.stableIdentity] = retainedState
                continue
            }

            guard let collapsedState = collapsedManagedState(for: state, reason: collapsedReason) else {
                transientManagedMountProbeFailures.remove(state.stableIdentity)
                continue
            }
            if !shouldAttempt(for: state.stableIdentity) {
                updatedStates[state.stableIdentity] = collapsedState
                lastError = collapsedState.reason
                continue
            }

            do {
                Log.warning("Global NTFS scan failed and managed mount for \(state.stableIdentity) collapsed; attempting recovery from last known state: \(scanError.localizedDescription)")
                let recoveredState = try recoverCollapsedKnownManagedVolume(
                    state: state,
                    consoleUser: consoleUser,
                    using: mounter,
                    allowLastKnownState: allowLastKnownState
                )
                updatedStates[state.stableIdentity] = recoveredState
                clearBackoff(state.stableIdentity)
            } catch {
                let delay = registerFailure(state.stableIdentity)
                let reason = "\(collapsedState.reason). Recovery failed: \(error.localizedDescription). retry in \(Int(delay))s"
                updatedStates[state.stableIdentity] = ManagedVolumeState(
                    deviceIdentifier: state.deviceIdentifier,
                    stableIdentity: state.stableIdentity,
                    parentWholeDisk: state.parentWholeDisk,
                    parentWholeDiskName: state.parentWholeDiskName,
                    volumeName: state.volumeName,
                    mountPoint: state.mountPoint,
                    isExternal: state.isExternal,
                    mode: .unmounted,
                    reason: reason,
                    lastTransitionAt: Date()
                )
                lastError = reason
                Log.warning("Collapsed managed mount recovery failed for \(state.stableIdentity): \(reason)")
            }
        }

	        guard attemptedRecovery else {
	            return nil
	        }
	
	        knownStates = updatedStates
	        refreshKnownDeviceIdentifiers()
	        return reconcileResult(from: updatedStates, lastError: lastError)
	    }

    private func collapsedManagedMountReason(for state: ManagedVolumeState) -> String? {
        let mountPointExists = mountPathExists(state.mountPoint)
        guard !mountPointExists || !managedMountPointIsActive(state.mountPoint) else {
            return nil
        }

        return mountPointExists
            ? "NTFS Access managed mount point is no longer an active filesystem mount while refreshing disk state; remount required"
            : "NTFS Access managed mount point disappeared while refreshing disk state; remount required"
    }

    private func collapsedManagedState(for state: ManagedVolumeState, reason: String? = nil) -> ManagedVolumeState? {
        let reason = reason ?? collapsedManagedMountReason(for: state)
        guard let reason else {
            return nil
        }
        return ManagedVolumeState(
            deviceIdentifier: state.deviceIdentifier,
            stableIdentity: state.stableIdentity,
            parentWholeDisk: state.parentWholeDisk,
            parentWholeDiskName: state.parentWholeDiskName,
            volumeName: state.volumeName,
            mountPoint: state.mountPoint,
            isExternal: state.isExternal,
            mode: .unmounted,
            reason: reason,
            lastTransitionAt: Date()
        )
    }

    private func recoverKnownVolumesAfterScanFailure(_ scanError: Error) -> ReconcileResult? {
        guard !knownStates.isEmpty else {
            return nil
        }

        var recoveredVolumes: [DiskVolume] = []
        var unrecoveredStableIdentities: [String] = []
        var removedStableIdentities: [String] = []
        let knownPairs = knownDeviceIdentifiersByStableIdentity.sorted { $0.key < $1.key }
        for (stableIdentity, identifier) in knownPairs {
            do {
                let recoveredVolume = try scanner.info(for: identifier)
                    .mergingPhysicalDriveMetadata(
                        parentWholeDisk: knownStates[stableIdentity]?.parentWholeDisk,
                        parentWholeDiskName: knownStates[stableIdentity]?.parentWholeDiskName
                    )
                if recoveredVolume.stableIdentity != stableIdentity {
                    removedStableIdentities.append(stableIdentity)
                    Log.warning("Known NTFS volume \(stableIdentity) at \(identifier) is now \(recoveredVolume.stableIdentity); removing stale managed state")
                } else if recoveredVolume.isNTFS {
                    recoveredVolumes.append(recoveredVolume)
                } else {
                    removedStableIdentities.append(stableIdentity)
                    let filesystem = recoveredVolume.filesystemName ?? recoveredVolume.filesystemType ?? "non-NTFS"
                    Log.warning("Known NTFS volume \(stableIdentity) at \(identifier) is now \(filesystem); removing stale managed state")
                }
            } catch {
                if scanner.deviceNoLongerPresent(error) {
                    removedStableIdentities.append(stableIdentity)
                    Log.warning("Known NTFS volume \(stableIdentity) at \(identifier) is no longer present; removing stale managed state")
                } else {
                    unrecoveredStableIdentities.append(stableIdentity)
                }
            }
        }
        guard !recoveredVolumes.isEmpty || !removedStableIdentities.isEmpty else {
            return nil
        }

        let statesToRetain = knownStatesWithCollapsedManagedMountsMarked(consoleUser: ConsoleUser.current())
        Log.warning("Global NTFS scan failed; refreshing \(recoveredVolumes.count) known NTFS volume(s) directly, removing \(removedStableIdentities.count) reformatted volume(s), and retaining \(unrecoveredStableIdentities.count) previous state(s): \(scanError.localizedDescription)")
        let refreshedResult: ReconcileResult
        if recoveredVolumes.isEmpty {
            knownStates = [:]
            refreshedResult = ReconcileResult(
                volumes: [],
                health: .healthy,
                lastError: "",
                managedVolumeCount: 0,
                degradedVolumeCount: 0
            )
        } else {
            refreshedResult = reconcile(
                volumes: recoveredVolumes,
                excludedRetainedStableIdentities: Set(removedStableIdentities)
            )
        }
        guard !unrecoveredStableIdentities.isEmpty || !removedStableIdentities.isEmpty else {
            return refreshedResult
        }

        var mergedStates = Dictionary(uniqueKeysWithValues: refreshedResult.volumes.map { ($0.stableIdentity, $0) })
        for stableIdentity in unrecoveredStableIdentities {
            guard !removedStableIdentities.contains(stableIdentity) else {
                continue
            }
            if let previous = statesToRetain[stableIdentity] {
                mergedStates[stableIdentity] = previous
            }
        }
        knownStates = mergedStates
        refreshKnownDeviceIdentifiers()
        pruneTracking(toActiveStableIdentities: Set(mergedStates.keys))
        return reconcileResult(from: mergedStates, lastError: refreshedResult.lastError)
    }

    private func reconcile(
        volumes: [DiskVolume],
        excludedRetainedStableIdentities: Set<String> = []
    ) -> ReconcileResult {
        let volumes = volumesWithDisambiguatedDuplicateIdentities(volumes)
        let consoleUser = ConsoleUser.current()
        var newStates: [String: ManagedVolumeState] = [:]
        var lastError = ""

        for volume in volumes {
            let id = volume.stableIdentity

            if userEjectedStableIdentities.contains(id) {
                newStates[id] = userEjectedState(for: volume)
                continue
            }

            if !shouldAttempt(for: id) {
                if let previous = knownStates[id] {
                    newStates[id] = previous
                }
                continue
            }

            do {
                let resultState = try convergeVolume(
                    volume: volume,
                    consoleUser: consoleUser
                )
                newStates[id] = resultState
                if resultState.mode == .unmounted && !resultState.reason.isEmpty {
                    lastError = resultState.reason
                    Log.warning("Reconcile reported \(id) unmounted: \(resultState.reason)")
                }
                if resultState.mode != .readWrite {
                    clearDurabilityEvidence(id)
                }
                clearBackoff(id)
            } catch {
                let delay = registerFailure(id)
                let reason = "\(error.localizedDescription). retry in \(Int(delay))s"
                lastError = reason
                Log.warning("Reconcile failed for \(id): \(reason)")

                newStates[id] = ManagedVolumeState(
                    volume: volume,
                    mode: .unmounted,
                    reason: reason,
                    lastTransitionAt: Date()
                )
            }
        }

        retainActiveKnownManagedMounts(
            missingFrom: volumes,
            excluding: excludedRetainedStableIdentities,
            into: &newStates
        )
        knownStates = newStates
        refreshKnownDeviceIdentifiers()
        pruneTracking(toActiveStableIdentities: Set(newStates.keys))
        return reconcileResult(from: newStates, lastError: lastError)
    }

    private func retainActiveKnownManagedMounts(
        missingFrom volumes: [DiskVolume],
        excluding excludedStableIdentities: Set<String>,
        into newStates: inout [String: ManagedVolumeState]
    ) {
        let seenStableIdentities = Set(volumes.map(\.stableIdentity))
        for state in knownStates.values
            where state.mode == .readWrite
                && isKnownNTFSAccessWritableState(state)
                && !seenStableIdentities.contains(state.stableIdentity)
                && !excludedStableIdentities.contains(state.stableIdentity)
                && newStates[state.stableIdentity] == nil {
            guard !state.mountPoint.isEmpty,
                  mountPathExists(state.mountPoint),
                  managedMountPointIsActive(state.mountPoint) else {
                continue
            }

            Log.warning("Retaining active NTFS Access mount \(state.stableIdentity) at \(state.mountPoint) after scan omitted it")
            newStates[state.stableIdentity] = state
        }
    }

    private func reconcileResult(from states: [String: ManagedVolumeState], lastError initialLastError: String) -> ReconcileResult {
        let degradedCount = states.values.filter { $0.mode == .readOnly }.count
        let warnings = states.values
            .filter { $0.mode == .readWrite && !$0.reason.isEmpty }
            .sorted { $0.deviceIdentifier < $1.deviceIdentifier }
        let unmountedIssue = states.values.first {
            $0.mode == .unmounted
                && !$0.reason.isEmpty
                && !isUserEjectedReason($0.reason)
        }
        var lastError = initialLastError
        if lastError.isEmpty, let unmountedIssue {
            lastError = unmountedIssue.reason
        }
        let health: ServiceHealth
        if !lastError.isEmpty {
            health = .error
        } else if degradedCount > 0 {
            health = .degradedReadOnly
        } else if !warnings.isEmpty {
            health = .warning
        } else {
            health = .healthy
        }

        return ReconcileResult(
            volumes: states.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier },
            health: health,
            lastError: lastError,
            managedVolumeCount: states.count,
            degradedVolumeCount: degradedCount,
            warningCount: warnings.count,
            lastWarning: warnings.first?.reason ?? ""
        )
    }

    private func convergeVolume(
        volume: DiskVolume,
        consoleUser: ConsoleUser
    ) throws -> ManagedVolumeState {
        guard let mounter else {
            throw AppError(message: "mounter unavailable")
        }

        if volume.isMounted && volume.isWritable {
            if let staleManagedState = staleManagedMountState(for: volume, consoleUser: consoleUser) {
                if let previous = knownStates[volume.stableIdentity],
                   let retainedState = retainedKnownReadWriteStateAfterTransientManagedMountProbeFailure(
                    previous: previous,
                    currentVolume: volume,
                    reason: staleManagedState.reason,
                    consoleUser: consoleUser
                   ) {
                    return retainedState
                }
                Log.warning("Managed mount for \(volume.stableIdentity) appears collapsed; forcing remount")
                return try remountCollapsedManagedVolume(
                    volume: volume,
                    fallbackState: staleManagedState,
                    consoleUser: consoleUser,
                    using: mounter
                )
            }

            transientManagedMountProbeFailures.remove(volume.stableIdentity)
            if let verificationFailure = unverifiedWritableState(
                for: volume,
                consoleUser: consoleUser,
                fallbackReason: "Volume reported writable, but NTFS Access could not verify signed-in user write access"
            ) {
                Log.warning("Writable verification failed for \(volume.stableIdentity): \(verificationFailure.reason)")
                if let retainedState = readWriteStateRetainedAfterTransientProbeTimeout(
                    volume: volume,
                    verificationFailure: verificationFailure
                ) {
                    clearNativeReadOnlyFallback(volume.stableIdentity)
                    confirmedWritableNTFSAccessDevices.insert(volume.stableIdentity)
                    return retainedState
                }

                nativeReadOnlyFallback.insert(volume.stableIdentity)
                confirmedWritableNTFSAccessDevices.remove(volume.stableIdentity)
                return verificationFailure
            }

            clearNativeReadOnlyFallback(volume.stableIdentity)
            if mountConfiguration.isManagedMountPoint(volume.mountPoint) || volume.isManagedByNTFSAccessBundle {
                confirmedWritableNTFSAccessDevices.insert(volume.stableIdentity)
            }
            return ManagedVolumeState(
                volume: volume,
                mode: .readWrite,
                reason: "",
                lastTransitionAt: Date()
            )
        }

        if volume.isMounted && !volume.isWritable {
            let isManagedReadOnlyMount = mountConfiguration.isManagedMountPoint(volume.mountPoint)
                || volume.isManagedByNTFSAccessBundle
            if isManagedReadOnlyMount {
                if let previous = knownStates[volume.stableIdentity],
                   previous.mode == .readWrite,
                   isKnownNTFSAccessWritableState(previous),
                   let verifiedState = verifiedMountedUserWritableState(
                    for: volume,
                    consoleUser: consoleUser,
                    unverifiedReason: "Managed NTFS Access mount reported read-only, but signed-in user write verification failed"
                   ) {
                    clearNativeReadOnlyFallback(volume.stableIdentity)
                    confirmedWritableNTFSAccessDevices.insert(volume.stableIdentity)
                    transientManagedMountProbeFailures.remove(volume.stableIdentity)
                    return verifiedState
                }

                Log.warning("Managed NTFS Access mount for \(volume.stableIdentity) is read-only; forcing writable remount")
                return try takeOverNativeReadOnlyVolume(
                    volume: volume,
                    consoleUser: consoleUser,
                    using: mounter
                )
            }

            if shouldAttemptNativeReadOnlyTakeover(for: volume, using: mounter) {
                return try takeOverNativeReadOnlyVolume(
                    volume: volume,
                    consoleUser: consoleUser,
                    using: mounter
                )
            }

            let hadFallback = nativeReadOnlyFallback.contains(volume.stableIdentity)
            nativeReadOnlyFallback.insert(volume.stableIdentity)
            clearBackoff(volume.stableIdentity)
            return ManagedVolumeState(
                volume: volume,
                mode: .readOnly,
                reason: readOnlyMountReason(
                    for: volume,
                    hadFallback: hadFallback,
                    previousReason: knownStates[volume.stableIdentity]?.reason
                ),
                lastTransitionAt: Date()
            )
        }

        let workingVolume = volume

        let probeResult = probe.checkWriteSafety(deviceNode: workingVolume.deviceNode)
        var fallbackReason = ""

        if probeResult.safeForWrite {
            do {
                try mountWritablePreferredPath(volume: workingVolume, user: consoleUser, using: mounter)
            } catch {
                Log.warning("Writable mount failed for \(volume.stableIdentity); falling back to read-only: \(error.localizedDescription)")
                fallbackReason = "Writable mount failed; fell back to read-only: \(error.localizedDescription)"
                do {
                    _ = try mounter.mountReadOnly(volume: workingVolume, user: consoleUser)
                } catch {
                    let ntfsAccessReadOnlyError = error
                    Log.warning("NTFS Access read-only mount failed for \(volume.stableIdentity); restoring native read-only: \(ntfsAccessReadOnlyError.localizedDescription)")
                    do {
                        try mounter.mountNativeReadOnly(deviceIdentifier: volume.deviceIdentifier)
                    } catch {
                        throw AppError(
                            message: "NTFS Access mount failed: \(fallbackReason). Native macOS read-only restore also failed: \(error.localizedDescription)"
                        )
                    }
                    let refreshed = try scanner.info(for: volume.deviceIdentifier)
                    return restoredNativeReadOnlyState(
                        refreshed: refreshed,
                        fallbackReason: fallbackReason,
                        nativeRestoreError: ntfsAccessReadOnlyError
                    )
                }
            }
        } else {
            if isRawDiskAccessDeniedMessage(probeResult.reason) {
                if formatterPersonalityIsReady() {
                    do {
                        try mountWritablePreferredPath(volume: workingVolume, user: consoleUser, using: mounter)
                        let refreshed = try scanner.info(for: workingVolume.deviceIdentifier)
                        if let verifiedState = verifiedWritableState(
                            for: refreshed,
                            consoleUser: consoleUser,
                            unverifiedReason: "Registered writable mount after raw probe denial could not be verified"
                        ) {
                            clearNativeReadOnlyFallback(volume.stableIdentity)
                            clearBackoff(volume.stableIdentity)
                            return verifiedState
                        }
                    } catch {
                        Log.warning("Registered writable mount after raw probe denial failed for \(volume.stableIdentity); restoring native read-only: \(error.localizedDescription)")
                        do {
                            try mounter.mountNativeReadOnly(deviceIdentifier: volume.deviceIdentifier)
                        } catch {
                            throw AppError(
                                message: "macOS denied raw disk access to \(volume.deviceNode). Registered NTFS Access mount failed: \(fallbackReason). Native macOS read-only restore also failed: \(error.localizedDescription)"
                            )
                        }
                        let refreshed = try scanner.info(for: volume.deviceIdentifier)
                            .mergingPhysicalDriveMetadata(from: volume)
                        nativeReadOnlyFallback.insert(volume.stableIdentity)
                        deferNativeReadOnlyTakeover(volume.stableIdentity)
                        clearBackoff(volume.stableIdentity)
                        return ManagedVolumeState(
                            volume: refreshed,
                            mode: refreshed.isMounted ? .readOnly : .unmounted,
                            reason: "NTFS Access mount failed after raw probe denial; restored native macOS read-only mount: \(error.localizedDescription)",
                            lastTransitionAt: Date()
                        )
                    }
                } else {
                    do {
                        try mounter.mountNativeReadOnly(deviceIdentifier: volume.deviceIdentifier)
                    } catch {
                        throw AppError(
                            message: "macOS denied raw disk access to \(volume.deviceNode). Native macOS read-only restore also failed: \(error.localizedDescription)"
                        )
                    }
                    let refreshed = try scanner.info(for: volume.deviceIdentifier)
                        .mergingPhysicalDriveMetadata(from: volume)
                    nativeReadOnlyFallback.insert(volume.stableIdentity)
                    deferNativeReadOnlyTakeover(volume.stableIdentity)
                    clearBackoff(volume.stableIdentity)
                    return ManagedVolumeState(
                        volume: refreshed,
                        mode: refreshed.isMounted ? .readOnly : .unmounted,
                        reason: "Native macOS read-only mount retained because raw disk access is not authorized. Grant Full Disk Access to NTFS Access.app, then reconnect the drive.",
                        lastTransitionAt: Date()
                    )
                }
            }

            do {
                _ = try mounter.mountReadOnly(volume: workingVolume, user: consoleUser)
            } catch {
                throw error
            }
        }

        let refreshed = refreshedStateAfterMount(
            deviceIdentifier: workingVolume.deviceIdentifier,
            fallbackVolume: workingVolume,
            fallbackMountPoint: mountConfiguration.mountPoint(for: workingVolume),
            expectedWritable: probeResult.safeForWrite && fallbackReason.isEmpty
        )
        let mode: VolumeMode
        var reason = fallbackReason.isEmpty ? (probeResult.safeForWrite ? "" : probeResult.reason) : fallbackReason

        if !refreshed.isMounted {
            mode = .unmounted
            if reason.isEmpty {
                reason = "mount command returned success but volume not mounted"
            }
        } else if let verifiedState = verifiedWritableState(
            for: refreshed,
            consoleUser: consoleUser,
            unverifiedReason: "mount command returned success but writable access could not be verified"
        ) {
            clearNativeReadOnlyFallback(volume.stableIdentity)
            mode = .readWrite
            reason = ""
            return verifiedState
        } else {
            nativeReadOnlyFallback.insert(volume.stableIdentity)
            mode = .readOnly
            if reason.isEmpty {
                reason = unverifiedWritableState(
                    for: refreshed,
                    consoleUser: consoleUser,
                    fallbackReason: "mount command returned success but writable access could not be verified"
                )?.reason ?? "volume mounted read-only"
            }
        }

        return ManagedVolumeState(
            volume: refreshed.mergingPhysicalDriveMetadata(from: volume),
            mode: mode,
            reason: reason,
            lastTransitionAt: Date()
        )
    }

    private func takeOverNativeReadOnlyVolume(
        volume: DiskVolume,
        consoleUser: ConsoleUser,
        using mounter: VolumeMounting
    ) throws -> ManagedVolumeState {
        let probeResult = probe.checkWriteSafety(deviceNode: volume.deviceNode)
        guard probeResult.safeForWrite
            || isRawDiskAccessDeniedMessage(probeResult.reason)
            || isTransientRawDeviceBusyMessage(probeResult.reason) else {
            nativeReadOnlyFallback.insert(volume.stableIdentity)
            clearBackoff(volume.stableIdentity)
            return ManagedVolumeState(
                volume: volume,
                mode: .readOnly,
                reason: probeResult.reason,
                lastTransitionAt: Date()
            )
        }

        let canUseRegisteredPersonality = formatterPersonalityIsReady()
        guard canUseRegisteredPersonality || mounter.canReadRawDevice(volume.deviceNode) else {
            return rawAccessDeniedNativeReadOnlyState(for: volume)
        }

        do {
            try ensureUnmounted(volume: volume, using: mounter)
        } catch {
            nativeReadOnlyFallback.insert(volume.stableIdentity)
            clearBackoff(volume.stableIdentity)
            return ManagedVolumeState(
                volume: volume,
                mode: .readOnly,
                reason: "Native macOS read-only mount retained because NTFS Access could not unmount it for takeover: \(error.localizedDescription)",
                lastTransitionAt: Date()
            )
        }

        let unmounted = unmountedStateAfterTakeoverUnmount(for: volume)

        guard probeResult.safeForWrite else {
            let bypassableProbeFailure = isRawDiskAccessDeniedMessage(probeResult.reason)
                || isTransientRawDeviceBusyMessage(probeResult.reason)
            if bypassableProbeFailure, formatterPersonalityIsReady() {
                do {
                    try mountWritablePreferredPath(volume: unmounted, user: consoleUser, using: mounter)
                    let refreshed = refreshedStateAfterMount(
                        deviceIdentifier: volume.deviceIdentifier,
                        fallbackVolume: unmounted,
                        fallbackMountPoint: mountConfiguration.mountPoint(for: unmounted),
                        expectedWritable: true
                    )
                    if let verifiedState = verifiedWritableState(
                        for: refreshed,
                        consoleUser: consoleUser,
                        unverifiedReason: "Registered writable takeover after raw probe denial could not be verified"
                    ) {
                        clearNativeReadOnlyFallback(volume.stableIdentity)
                        clearBackoff(volume.stableIdentity)
                        return verifiedState
                    }
                } catch {
                    Log.warning("Registered writable takeover after raw probe denial failed for \(volume.stableIdentity): \(error.localizedDescription)")
                    nativeReadOnlyFallback.insert(volume.stableIdentity)
                    deferNativeReadOnlyTakeover(volume.stableIdentity)
                    clearBackoff(volume.stableIdentity)
                }
            }

            try mounter.mountNativeReadOnly(deviceIdentifier: volume.deviceIdentifier)
            let refreshed = refreshedStateAfterMount(
                deviceIdentifier: volume.deviceIdentifier,
                fallbackVolume: unmounted,
                fallbackMountPoint: "/Volumes/\(volume.volumeName)",
                expectedWritable: false
            )
            nativeReadOnlyFallback.insert(volume.stableIdentity)
            if isRawDiskAccessDeniedMessage(probeResult.reason) {
                deferNativeReadOnlyTakeover(volume.stableIdentity)
            }
            clearBackoff(volume.stableIdentity)
            return ManagedVolumeState(
                volume: refreshed,
                mode: .readOnly,
                reason: "Native macOS read-only mount retained because writable NTFS takeover was blocked by macOS raw disk access policy: \(probeResult.reason)",
                lastTransitionAt: Date()
            )
        }

        var fallbackReason = ""
        do {
            try mountWritablePreferredPath(volume: unmounted, user: consoleUser, using: mounter)
        } catch {
            Log.warning("Writable takeover failed for \(volume.stableIdentity); falling back to NTFS Access read-only: \(error.localizedDescription)")
            fallbackReason = "Writable takeover failed; fell back to NTFS Access read-only: \(error.localizedDescription)"
            if isRawDiskAccessDeniedMessage(error.localizedDescription) {
                nativeReadOnlyFallback.insert(volume.stableIdentity)
                deferNativeReadOnlyTakeover(volume.stableIdentity)
                clearBackoff(volume.stableIdentity)
                do {
                    try mounter.mountNativeReadOnly(deviceIdentifier: volume.deviceIdentifier)
                } catch {
                    throw AppError(
                        message: "\(fallbackReason). Native macOS read-only restore also failed: \(error.localizedDescription)"
                    )
                }
                let refreshed = refreshedStateAfterMount(
                    deviceIdentifier: volume.deviceIdentifier,
                    fallbackVolume: unmounted,
                    fallbackMountPoint: "/Volumes/\(volume.volumeName)",
                    expectedWritable: false
                )
                return ManagedVolumeState(
                    volume: refreshed,
                    mode: refreshed.isMounted ? .readOnly : .unmounted,
                    reason: "Native macOS read-only mount retained because writable NTFS takeover was blocked by macOS raw disk access policy: \(error.localizedDescription)",
                    lastTransitionAt: Date()
                )
            }
            do {
                _ = try mounter.mountReadOnly(volume: unmounted, user: consoleUser)
            } catch {
                Log.warning("NTFS Access read-only takeover failed for \(volume.stableIdentity); restoring native read-only: \(error.localizedDescription)")
                try mounter.mountNativeReadOnly(deviceIdentifier: volume.deviceIdentifier)
                let refreshed = refreshedStateAfterMount(
                    deviceIdentifier: volume.deviceIdentifier,
                    fallbackVolume: unmounted,
                    fallbackMountPoint: "/Volumes/\(volume.volumeName)",
                    expectedWritable: false
                )
                nativeReadOnlyFallback.insert(volume.stableIdentity)
                clearBackoff(volume.stableIdentity)
                return ManagedVolumeState(
                    volume: refreshed,
                    mode: .readOnly,
                    reason: "NTFS Access takeover failed; restored native macOS read-only mount: \(error.localizedDescription)",
                    lastTransitionAt: Date()
                )
            }
        }

        let refreshed = refreshedStateAfterMount(
            deviceIdentifier: volume.deviceIdentifier,
            fallbackVolume: unmounted,
            fallbackMountPoint: mountConfiguration.mountPoint(for: unmounted),
            expectedWritable: true
        )
        if let verifiedState = verifiedWritableState(
            for: refreshed,
            consoleUser: consoleUser,
            unverifiedReason: "NTFS Access takeover did not produce a verified writable mount"
        ) {
            clearNativeReadOnlyFallback(volume.stableIdentity)
            clearBackoff(volume.stableIdentity)
            confirmedWritableNTFSAccessDevices.insert(refreshed.stableIdentity)
            return verifiedState
        }

        return readOnlyOrUnmountedStateAfterTakeover(
            refreshed: refreshed,
            fallbackReason: fallbackReason.isEmpty ? "NTFS Access takeover did not produce a writable mount" : fallbackReason
        )
    }

    private func rawAccessDeniedNativeReadOnlyState(for volume: DiskVolume) -> ManagedVolumeState {
        nativeReadOnlyFallback.insert(volume.stableIdentity)
        deferNativeReadOnlyTakeover(volume.stableIdentity)
        clearBackoff(volume.stableIdentity)
        return ManagedVolumeState(
            volume: volume,
            mode: .readOnly,
            reason: "Native macOS read-only mount retained because raw disk access is not authorized. If NTFS Access.app is already enabled in Full Disk Access, remove it, add /Applications/NTFS Access.app again, then retry.",
            lastTransitionAt: Date()
        )
    }

    private func restoredNativeReadOnlyState(
        refreshed: DiskVolume,
        fallbackReason: String,
        nativeRestoreError: Error
    ) -> ManagedVolumeState {
        let reason: String
        if !fallbackReason.isEmpty {
            reason = "\(fallbackReason). Restored native macOS read-only mount after NTFS Access read-only fallback failed: \(nativeRestoreError.localizedDescription)"
        } else {
            reason = "NTFS Access mount failed; restored native macOS read-only mount: \(nativeRestoreError.localizedDescription)"
        }
        return readOnlyOrUnmountedStateAfterTakeover(refreshed: refreshed, fallbackReason: reason)
    }

    private func readOnlyOrUnmountedStateAfterTakeover(
        refreshed: DiskVolume,
        fallbackReason: String
    ) -> ManagedVolumeState {
        nativeReadOnlyFallback.insert(refreshed.stableIdentity)
        confirmedWritableNTFSAccessDevices.remove(refreshed.stableIdentity)
        clearBackoff(refreshed.stableIdentity)
        return ManagedVolumeState(
            volume: refreshed,
            mode: refreshed.isMounted ? .readOnly : .unmounted,
            reason: fallbackReason,
            lastTransitionAt: Date()
        )
    }

    private func readOnlyMountReason(
        for volume: DiskVolume,
        hadFallback: Bool,
        previousReason: String? = nil
    ) -> String {
        if hadFallback {
            if let previousReason, !previousReason.isEmpty {
                return previousReason
            }
            return "Native macOS read-only mount retained after writable takeover failed"
        }

        if mountConfiguration.isManagedMountPoint(volume.mountPoint) {
            return "NTFS volume mounted read-only by NTFS Access"
        }

        return "NTFS volume is mounted read-only outside the NTFS Access managed mountpoint"
    }

    private func mountWritablePreferredPath(
        volume: DiskVolume,
        user: ConsoleUser,
        using mounter: VolumeMounting
    ) throws {
        if shouldUseRegisteredFilesystemPersonality(for: volume) {
            do {
                try mounter.mountUsingRegisteredPersonality(deviceIdentifier: volume.deviceIdentifier, readOnly: false)
                if let refreshed = try? scanner.info(for: volume.deviceIdentifier) {
                    if registeredWritableMountIsUsable(refreshed, by: user) {
                        confirmedWritableNTFSAccessDevices.insert(volume.stableIdentity)
                        return
                    }

                    let mountPoint = refreshed.mountPoint ?? "(none)"
                    Log.warning("Registered filesystem mount for \(volume.stableIdentity) completed but is not writable and user-accessible at \(mountPoint); retrying direct NTFS Access path")
                    if refreshed.isMounted {
                        try ensureUnmounted(volume: volume, using: mounter)
                    }
                } else {
                    Log.warning("Registered filesystem mount for \(volume.stableIdentity) completed but disk state could not be refreshed; retrying direct NTFS Access path")
                    try? mounter.unmount(deviceIdentifier: volume.deviceIdentifier, mountPoint: nil, force: true)
                }
            } catch {
                Log.warning("Registered filesystem mount failed for \(volume.stableIdentity); retrying direct NTFS Access path: \(error.localizedDescription)")
                if let refreshed = try? scanner.info(for: volume.deviceIdentifier), refreshed.isMounted {
                    do {
                        try ensureUnmounted(volume: volume, using: mounter)
                    } catch {
                        Log.warning("Unable to clear mount left after registered filesystem failure for \(volume.stableIdentity): \(error.localizedDescription)")
                    }
                }
            }
        }

        _ = try mounter.mountReadWrite(volume: volume, user: user)
    }

    private func registeredWritableMountIsUsable(_ volume: DiskVolume, by consoleUser: ConsoleUser) -> Bool {
        verifiedWritableState(
            for: volume,
            consoleUser: consoleUser,
            unverifiedReason: "registered filesystem mount is not verified writable"
        ) != nil
    }

    private func recoverCollapsedKnownManagedVolume(
        state: ManagedVolumeState,
        consoleUser: ConsoleUser,
        using mounter: VolumeMounting,
        allowLastKnownState: Bool
    ) throws -> ManagedVolumeState {
        let currentVolume: DiskVolume
        do {
            let refreshed = try scanner.info(for: state.deviceIdentifier)
                .mergingPhysicalDriveMetadata(
                    parentWholeDisk: state.parentWholeDisk,
                    parentWholeDiskName: state.parentWholeDiskName
                )
            guard refreshed.stableIdentity == state.stableIdentity,
                  refreshed.isNTFS else {
                throw AppError(message: "could not verify current identity for \(state.stableIdentity) at \(state.deviceIdentifier)")
            }
            currentVolume = refreshed
        } catch {
            guard allowLastKnownState else {
                throw AppError(message: "could not verify current identity for \(state.stableIdentity) at \(state.deviceIdentifier)")
            }
            Log.warning("Recovering \(state.stableIdentity) from last known state because diskutil info is unavailable: \(error.localizedDescription)")
            currentVolume = DiskVolume(
                deviceIdentifier: state.deviceIdentifier,
                deviceNode: "/dev/\(state.deviceIdentifier)",
                stableIdentity: state.stableIdentity,
                parentWholeDisk: state.parentWholeDisk,
                parentWholeDiskName: state.parentWholeDiskName,
                volumeName: state.volumeName,
                mediaName: state.volumeName,
                filesystemType: "ntfs",
                filesystemName: "Windows NT Filesystem",
                mountPoint: nil,
                isMounted: false,
                isWritable: false,
                isInternal: !state.isExternal
            )
        }

        let volume = DiskVolume(
            deviceIdentifier: currentVolume.deviceIdentifier,
            deviceNode: currentVolume.deviceNode,
            stableIdentity: currentVolume.stableIdentity,
            volumeUUID: currentVolume.volumeUUID,
            diskUUID: currentVolume.diskUUID,
            mediaUUID: currentVolume.mediaUUID,
            parentWholeDisk: currentVolume.parentWholeDisk,
            parentWholeDiskName: currentVolume.parentWholeDiskName,
            partitionMapPartitionOffset: currentVolume.partitionMapPartitionOffset,
            size: currentVolume.size,
            volumeName: currentVolume.volumeName,
            mediaName: currentVolume.mediaName,
            filesystemType: currentVolume.filesystemType,
            filesystemName: currentVolume.filesystemName,
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: currentVolume.isInternal
        )
        let staleMountPoint = state.mountPoint.isEmpty
            ? mountConfiguration.mountPoint(for: volume)
            : state.mountPoint
        try? mounter.unmount(
            deviceIdentifier: currentVolume.deviceIdentifier,
            mountPoint: staleMountPoint,
            force: true
        )
        _ = try mounter.mountReadWrite(volume: volume, user: consoleUser)

        let refreshed = refreshedStateAfterMount(
            deviceIdentifier: currentVolume.deviceIdentifier,
            fallbackVolume: volume,
            fallbackMountPoint: mountConfiguration.mountPoint(for: volume),
            expectedWritable: true
        )
        if let verifiedState = verifiedWritableState(
            for: refreshed,
            consoleUser: consoleUser,
            unverifiedReason: "Managed mount recovery did not produce a verified writable mount"
        ) {
            confirmedWritableNTFSAccessDevices.insert(state.stableIdentity)
            nativeReadOnlyFallback.remove(state.stableIdentity)
            return verifiedState
        }

        return ManagedVolumeState(
            deviceIdentifier: currentVolume.deviceIdentifier,
            stableIdentity: state.stableIdentity,
            parentWholeDisk: state.parentWholeDisk,
            parentWholeDiskName: state.parentWholeDiskName,
            volumeName: state.volumeName,
            mountPoint: refreshed.mountPoint ?? state.mountPoint,
            isExternal: state.isExternal,
            mode: refreshed.isMounted ? .readOnly : .unmounted,
            reason: "Managed mount recovery did not produce a writable mount",
            lastTransitionAt: Date()
        )
    }

    private func unmountedStateAfterTakeoverUnmount(for volume: DiskVolume) -> DiskVolume {
        if let refreshed = try? scanner.info(for: volume.deviceIdentifier),
           refreshed.stableIdentity == volume.stableIdentity {
            return refreshed
                .mergingPhysicalDriveMetadata(from: volume)
                .copyForMountState(mountPoint: nil, isMounted: false, isWritable: false)
        }

        Log.warning("Disk state for \(volume.stableIdentity) could not be refreshed after native read-only unmount; continuing writable takeover from last known volume identity")
        return volume.copyForMountState(mountPoint: nil, isMounted: false, isWritable: false)
    }

    private func refreshedStateAfterMount(
        deviceIdentifier: String,
        fallbackVolume: DiskVolume,
        fallbackMountPoint: String,
        expectedWritable: Bool
    ) -> DiskVolume {
        if let refreshed = try? scanner.info(for: deviceIdentifier),
           refreshed.stableIdentity == fallbackVolume.stableIdentity {
            return refreshed.mergingPhysicalDriveMetadata(from: fallbackVolume)
        }

        let expectedMode = expectedWritable ? "writable" : "read-only"
        Log.warning("Disk state for \(fallbackVolume.stableIdentity) could not be refreshed after \(expectedMode) mount; reporting provisional state as unverified")
        if expectedWritable,
           !fallbackMountPoint.isEmpty,
           mountPathExists(fallbackMountPoint),
           managedMountPointIsActive(fallbackMountPoint) {
            return fallbackVolume.copyForMountState(
                mountPoint: fallbackMountPoint,
                isMounted: true,
                isWritable: true
            )
        }

        return fallbackVolume.copyForMountState(
            mountPoint: fallbackMountPoint,
            isMounted: false,
            isWritable: false
        )
    }

    private func shouldUseRegisteredFilesystemPersonality(for volume: DiskVolume) -> Bool {
        volume.isManagedByNTFSAccessBundle || formatterPersonalityIsReady()
    }

    private func formatterPersonalityIsReady() -> Bool {
        let report = dependencyCheck()
        return report.formatterBundleInstalled
            && report.formatterPersonalityRegistered
            && report.formatterProbeOrders.contains { _, order in order <= 1_000 }
    }

    private func isKnownNTFSAccessWritableState(_ state: ManagedVolumeState) -> Bool {
        mountConfiguration.isManagedMountPoint(state.mountPoint)
            || confirmedWritableNTFSAccessDevices.contains(state.stableIdentity)
    }

    private func readWriteStateRetainedAfterTransientProbeTimeout(
        volume: DiskVolume,
        verificationFailure: ManagedVolumeState
    ) -> ManagedVolumeState? {
        guard isTransientWriteProbeTimeout(verificationFailure.reason),
              let previous = knownStates[volume.stableIdentity],
              previous.mode == .readWrite,
              isKnownNTFSAccessWritableState(previous),
              volume.isMounted,
              volume.isWritable,
              let mountPoint = volume.mountPoint,
              !mountPoint.isEmpty,
              mountPathExists(mountPoint),
              managedMountPointIsActive(mountPoint) else {
            return nil
        }

        transientManagedMountProbeFailures.remove(volume.stableIdentity)
        let warning = "Writable verification timed out while the volume was busy; retaining the last verified NTFS Access read-write state"
        Log.warning("\(warning) for \(volume.stableIdentity)")
        return ManagedVolumeState(
            volume: volume,
            mountPoint: mountPoint,
            mode: .readWrite,
            reason: warning,
            lastTransitionAt: previous.lastTransitionAt
        )
    }

    private func isTransientWriteProbeTimeout(_ reason: String) -> Bool {
        let lowercased = reason.lowercased()
        let isWriteProbeFailure = lowercased.contains("signed-in user write probe failed")
        let isTimeout = lowercased.contains("timed out")
            || lowercased.contains("timeout")
            || lowercased.contains("command timed out")
            || lowercased.contains("not responding")
        return isWriteProbeFailure && isTimeout
    }

    private func retainedKnownReadWriteStateAfterTransientManagedMountProbeFailure(
        previous: ManagedVolumeState,
        currentVolume: DiskVolume?,
        reason: String,
        consoleUser: ConsoleUser
    ) -> ManagedVolumeState? {
        guard previous.mode == .readWrite,
              isKnownNTFSAccessWritableState(previous),
              !previous.mountPoint.isEmpty else {
            return nil
        }

        if let currentVolume,
           let currentMountPoint = currentVolume.mountPoint,
           currentVolume.isMounted,
           currentVolume.isWritable,
           !currentMountPoint.isEmpty,
           currentMountPoint != previous.mountPoint {
            return nil
        }

        guard transientManagedMountProbeFailures.insert(previous.stableIdentity).inserted else {
            return nil
        }

        let warning = "Managed mount state probe was temporarily inconclusive; retaining the last verified NTFS Access read-write state"
        Log.warning("\(warning) for \(previous.stableIdentity): \(reason)")
        return ManagedVolumeState(
            deviceIdentifier: currentVolume?.deviceIdentifier ?? previous.deviceIdentifier,
            stableIdentity: previous.stableIdentity,
            parentWholeDisk: currentVolume?.parentWholeDisk ?? previous.parentWholeDisk,
            parentWholeDiskName: currentVolume?.parentWholeDiskName ?? previous.parentWholeDiskName,
            volumeName: currentVolume?.volumeName ?? previous.volumeName,
            mountPoint: currentVolume?.mountPoint ?? previous.mountPoint,
            isExternal: currentVolume?.isExternal ?? previous.isExternal,
            mode: .readWrite,
            reason: warning,
            lastTransitionAt: previous.lastTransitionAt
        )
    }

    private func shouldAttemptNativeReadOnlyTakeover(for volume: DiskVolume, using mounter: VolumeMounting) -> Bool {
        guard nativeReadOnlyFallback.contains(volume.stableIdentity) else {
            return true
        }

        return canRetryNativeReadOnlyFallback(volume, using: mounter)
    }

    private func canRetryNativeReadOnlyFallback(_ volume: DiskVolume, using mounter: VolumeMounting) -> Bool {
        let probeResult = probe.checkWriteSafety(deviceNode: volume.deviceNode)
        guard probeResult.safeForWrite else {
            guard isRawDiskAccessDeniedMessage(probeResult.reason) else {
                return false
            }

            guard let nextAttempt = nextNativeReadOnlyTakeoverAttemptAt[volume.stableIdentity] else {
                return true
            }

            return now() >= nextAttempt
        }

        if formatterPersonalityIsReady() {
            if let nextAttempt = nextNativeReadOnlyTakeoverAttemptAt[volume.stableIdentity],
               now() < nextAttempt {
                return false
            }
            return true
        }

        if shouldCheckRawAccessReadiness(for: volume.stableIdentity) {
            if mounter.canReadRawDevice(volume.deviceNode) {
                clearNativeReadOnlyRetryDelay(volume.stableIdentity)
                return true
            }
            deferRawAccessReadinessCheck(volume.stableIdentity)
        }

        if let nextAttempt = nextNativeReadOnlyTakeoverAttemptAt[volume.stableIdentity],
           now() < nextAttempt {
            return false
        }

        return true
    }

    private func deferNativeReadOnlyTakeover(_ deviceIdentifier: String) {
        let currentDate = now()
        nextNativeReadOnlyTakeoverAttemptAt[deviceIdentifier] = currentDate.addingTimeInterval(nativeReadOnlyTakeoverRetryInterval)
        nextRawAccessReadinessCheckAt[deviceIdentifier] = currentDate.addingTimeInterval(rawAccessReadinessCheckInterval)
    }

    private func shouldCheckRawAccessReadiness(for deviceIdentifier: String) -> Bool {
        guard rawAccessReadinessCheckInterval > 0 else {
            return true
        }

        guard let nextCheck = nextRawAccessReadinessCheckAt[deviceIdentifier] else {
            return true
        }

        return now() >= nextCheck
    }

    private func deferRawAccessReadinessCheck(_ deviceIdentifier: String) {
        nextRawAccessReadinessCheckAt[deviceIdentifier] = now().addingTimeInterval(rawAccessReadinessCheckInterval)
    }

    private func clearNativeReadOnlyRetryDelay(_ deviceIdentifier: String) {
        nextNativeReadOnlyTakeoverAttemptAt.removeValue(forKey: deviceIdentifier)
        nextRawAccessReadinessCheckAt.removeValue(forKey: deviceIdentifier)
    }

    private func clearNativeReadOnlyFallback(_ deviceIdentifier: String) {
        nativeReadOnlyFallback.remove(deviceIdentifier)
        clearNativeReadOnlyRetryDelay(deviceIdentifier)
    }

    private func clearDurabilityEvidence(_ stableIdentity: String) {
    }

    private func remountCollapsedManagedVolume(
        volume: DiskVolume,
        fallbackState: ManagedVolumeState,
        consoleUser: ConsoleUser,
        using mounter: VolumeMounting
    ) throws -> ManagedVolumeState {
        do {
            try ensureUnmounted(volume: volume, using: mounter)
            let unmounted = try scanner.info(for: volume.deviceIdentifier)
                .mergingPhysicalDriveMetadata(from: volume)
            try mountWritablePreferredPath(volume: unmounted, user: consoleUser, using: mounter)
            let refreshed = try scanner.info(for: volume.deviceIdentifier)
                .mergingPhysicalDriveMetadata(from: volume)
            if let verifiedState = verifiedWritableState(
                for: refreshed,
                consoleUser: consoleUser,
                unverifiedReason: "Managed mount recovery did not produce a verified writable mount"
            ) {
                nativeReadOnlyFallback.remove(volume.stableIdentity)
                clearBackoff(volume.stableIdentity)
                return verifiedState
            }

            return ManagedVolumeState(
                volume: refreshed,
                mode: refreshed.isMounted ? .readOnly : .unmounted,
                reason: "Managed mount recovery did not produce a writable mount",
                lastTransitionAt: Date()
            )
        } catch {
            throw AppError(message: "\(fallbackState.reason). Remount recovery failed: \(error.localizedDescription)")
        }
    }

    private func isRawDiskAccessDeniedMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        let mentionsDisk = lowercased.contains("/dev/disk") || lowercased.contains("/dev/rdisk")
        let denied = lowercased.contains("operation not permitted")
            || lowercased.contains("permission denied")
            || lowercased.contains("denied raw disk access")
            || lowercased.contains("raw disk access")
        return mentionsDisk && denied
    }

    private func isTransientRawDeviceBusyMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        let mentionsDisk = lowercased.contains("/dev/disk") || lowercased.contains("/dev/rdisk")
        let busy = lowercased.contains("resource busy") || lowercased.contains("device busy")
        return mentionsDisk && busy
    }

    private func isDiskArbitrationTimeout(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("diskutil")
            && (
                message.contains("timed out")
                    || message.contains("timeout")
                    || message.contains("not responding")
            )
    }

    private func staleManagedMountState(for volume: DiskVolume, consoleUser: ConsoleUser) -> ManagedVolumeState? {
        let isManagedMountPoint = mountConfiguration.isManagedMountPoint(volume.mountPoint)
        let isNTFSAccessMount = isManagedMountPoint
            || volume.isManagedByNTFSAccessBundle
            || confirmedWritableNTFSAccessDevices.contains(volume.stableIdentity)
        guard isNTFSAccessMount else {
            return nil
        }

        guard let mountPoint = volume.mountPoint, !mountPoint.isEmpty else {
            return nil
        }

        let exists = mountPathExists(mountPoint)
        let activeMount = exists && managedMountPointIsActive(mountPoint)
        if activeMount && (!isManagedMountPoint || isManagedMountPointAccessible(mountPoint, to: consoleUser)) {
            return nil
        }

        clearBackoff(volume.stableIdentity)
        let reason: String
        if !exists {
            reason = "NTFS Access managed mount point is missing; the filesystem mount likely collapsed and needs remount"
        } else if !activeMount {
            reason = "NTFS Access managed mount point is not an active filesystem mount; the filesystem mount likely collapsed and needs remount"
        } else {
            reason = "NTFS Access managed mount point is not accessible to the signed-in user; the filesystem mount likely needs remount"
        }
        return ManagedVolumeState(
            volume: volume,
            mountPoint: mountPoint,
            mode: .unmounted,
            reason: reason,
            lastTransitionAt: Date()
        )
    }

    private func isManagedMountPointAccessible(_ mountPoint: String, to consoleUser: ConsoleUser) -> Bool {
        var statBuffer = stat()
        guard stat(mountPoint, &statBuffer) == 0 else {
            Log.warning("Managed mount point stat failed for \(mountPoint)")
            return false
        }

        let mode = statBuffer.st_mode
        let ownerCanAccess = statBuffer.st_uid == consoleUser.uid && (mode & S_IRWXU) == S_IRWXU
        let groupCanAccess = statBuffer.st_gid == consoleUser.gid && (mode & S_IRWXG) == S_IRWXG
        let everyoneCanAccess = (mode & S_IRWXO) == S_IRWXO
        let accessible = ownerCanAccess || groupCanAccess || everyoneCanAccess
        if !accessible {
            Log.warning("Managed mount point \(mountPoint) permissions do not allow uid \(consoleUser.uid) gid \(consoleUser.gid): owner=\(statBuffer.st_uid) group=\(statBuffer.st_gid) mode=\(String(mode & 0o777, radix: 8))")
        }
        return accessible
    }

    private func verifiedWritableState(
        for volume: DiskVolume,
        consoleUser: ConsoleUser,
        unverifiedReason: String
    ) -> ManagedVolumeState? {
        guard volume.isMounted, volume.isWritable else {
            return nil
        }

        return verifiedMountedUserWritableState(
            for: volume,
            consoleUser: consoleUser,
            unverifiedReason: unverifiedReason
        )
    }

    private func verifiedMountedUserWritableState(
        for volume: DiskVolume,
        consoleUser: ConsoleUser,
        unverifiedReason: String
    ) -> ManagedVolumeState? {
        guard volume.isMounted else {
            return nil
        }

        if let failure = unverifiedWritableState(
            for: volume,
            consoleUser: consoleUser,
            fallbackReason: unverifiedReason
        ) {
            Log.warning("Writable verification failed for \(volume.stableIdentity): \(failure.reason)")
            return nil
        }

        return ManagedVolumeState(
            volume: volume,
            mode: .readWrite,
            reason: "",
            lastTransitionAt: Date()
        )
    }

    private func unverifiedWritableState(
        for volume: DiskVolume,
        consoleUser: ConsoleUser,
        fallbackReason: String
    ) -> ManagedVolumeState? {
        guard let mountPoint = volume.mountPoint, !mountPoint.isEmpty else {
            return ManagedVolumeState(
                volume: volume,
                mountPoint: "",
                mode: .unmounted,
                reason: "\(fallbackReason): missing mount point",
                lastTransitionAt: Date()
            )
        }

        if !mountPathExists(mountPoint) {
            Log.warning("Writable verification could not preflight mount point path \(mountPoint); continuing to signed-in user write probe")
        }

        if mountPathExists(mountPoint),
           mountConfiguration.isManagedMountPoint(mountPoint),
           !managedMountPointIsActive(mountPoint) {
            return ManagedVolumeState(
                volume: volume,
                mountPoint: mountPoint,
                mode: .unmounted,
                reason: "\(fallbackReason): managed mount point is not an active filesystem mount",
                lastTransitionAt: Date()
            )
        }

        if case let .failure(error) = mountPointWriteProbe(mountPoint, consoleUser) {
            return ManagedVolumeState(
                volume: volume,
                mountPoint: mountPoint,
                mode: .readOnly,
                reason: "\(fallbackReason): signed-in user write probe failed at \(mountPoint): \(error.localizedDescription)",
                lastTransitionAt: Date()
            )
        }

        return nil
    }

    private func shouldAttempt(for identifier: String) -> Bool {
        guard let nextRetryAt = nextRetryAt[identifier] else {
            return true
        }
        return Date() >= nextRetryAt
    }

    private func registerFailure(_ identifier: String) -> TimeInterval {
        let count = (failureCount[identifier] ?? 0) + 1
        failureCount[identifier] = count

        let delay = min(300, pow(2.0, Double(min(count, 8))))
        nextRetryAt[identifier] = now().addingTimeInterval(delay)
        return delay
    }

    private func clearBackoff(_ identifier: String) {
        failureCount.removeValue(forKey: identifier)
        nextRetryAt.removeValue(forKey: identifier)
    }

    private func refreshKnownDeviceIdentifiers() {
        knownDeviceIdentifiersByStableIdentity = Dictionary(
            uniqueKeysWithValues: knownStates.values.map { ($0.stableIdentity, $0.deviceIdentifier) }
        )
    }

    private func pruneTracking(toActiveStableIdentities activeStableIdentities: Set<String>) {
        failureCount = failureCount.filter { activeStableIdentities.contains($0.key) }
        nextRetryAt = nextRetryAt.filter { activeStableIdentities.contains($0.key) }
        nativeReadOnlyFallback = nativeReadOnlyFallback.filter { activeStableIdentities.contains($0) }
        nextNativeReadOnlyTakeoverAttemptAt = nextNativeReadOnlyTakeoverAttemptAt.filter { activeStableIdentities.contains($0.key) }
        nextRawAccessReadinessCheckAt = nextRawAccessReadinessCheckAt.filter { activeStableIdentities.contains($0.key) }
        confirmedWritableNTFSAccessDevices = confirmedWritableNTFSAccessDevices.filter { activeStableIdentities.contains($0) }
        transientManagedMountProbeFailures = transientManagedMountProbeFailures.filter { activeStableIdentities.contains($0) }
        userEjectedStableIdentities = userEjectedStableIdentities.filter { activeStableIdentities.contains($0) }
    }

    private func userEjectedState(for volume: DiskVolume) -> ManagedVolumeState {
        ManagedVolumeState(
            volume: volume,
            mountPoint: "",
            mode: .unmounted,
            reason: "User ejected this NTFS partition. Click Fix to mount it again.",
            lastTransitionAt: Date()
        )
    }

    private func isUserEjectedReason(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("user ejected")
    }

    private func volumesWithDisambiguatedDuplicateIdentities(_ volumes: [DiskVolume]) -> [DiskVolume] {
        let duplicates = duplicateStableIdentities(in: volumes)
        guard !duplicates.isEmpty else {
            return volumes
        }

        return volumes.map { volume in
            guard duplicates.contains(volume.stableIdentity) else {
                return volume
            }
            return volume.copyWithStableIdentity(disambiguatedStableIdentity(for: volume))
        }
    }

    private func duplicateStableIdentities(in volumes: [DiskVolume]) -> Set<String> {
        var counts: [String: Int] = [:]
        for volume in volumes {
            counts[volume.stableIdentity, default: 0] += 1
        }
        return Set(counts.compactMap { identity, count in
            count > 1 ? identity : nil
        })
    }

    private func disambiguatedStableIdentity(for volume: DiskVolume) -> String {
        let parent = volume.parentWholeDisk ?? "device-\(volume.deviceIdentifier)"
        let offset = volume.partitionMapPartitionOffset.map(String.init) ?? "unknown-offset"
        let size = volume.size.map(String.init) ?? "unknown-size"
        return "\(volume.stableIdentity)-layout-\(parent)-\(offset)-\(size)"
    }

    private static func defaultManagedMountPointIsActive(_ mountPoint: String) -> Bool {
        var statBuffer = statfs()
        guard statfs(mountPoint, &statBuffer) == 0 else {
            return false
        }

        let mountedOn = mountPointName(from: statBuffer)
        return normalizedPath(mountedOn) == normalizedPath(mountPoint)
    }

    private static func defaultMountPointWriteProbe(
        mountPoint: String,
        consoleUser: ConsoleUser
    ) -> Result<Void, Error> {
        let probeName = ".ntfsaccess-write-probe-\(UUID().uuidString)"
        let probeURL = URL(fileURLWithPath: mountPoint, isDirectory: true)
            .appendingPathComponent(probeName)
        let probePath = probeURL.path
        let command = """
        set -e
        umask 077
        printf 'ntfsaccess-write-probe' > "$1"
        /bin/cat "$1" > /dev/null
        /bin/rm -f "$1"
        """

        do {
            _ = try Shell.runChecked(
                "/bin/launchctl",
                [
                    "asuser",
                    "\(consoleUser.uid)",
                    "/usr/bin/sudo",
                    "-n",
                    "-u",
                    "#\(consoleUser.uid)",
                    "-g",
                    "#\(consoleUser.gid)",
                    "/bin/sh",
                    "-c",
                    command,
                    "ntfsaccess-write-probe",
                    probePath
                ],
                timeout: 8
            )
            return .success(())
        } catch {
            try? FileManager.default.removeItem(at: probeURL)
            return .failure(error)
        }
    }

    private static func mountPointName(from statBuffer: statfs) -> String {
        var mountPointName = statBuffer.f_mntonname
        let capacity = MemoryLayout.size(ofValue: mountPointName)
        return withUnsafePointer(to: &mountPointName) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    private func ensureUnmounted(volume: DiskVolume, using mounter: VolumeMounting) throws {
        let maxAttempts = 6
        var lastMountedState: DiskVolume?

        for attempt in 0..<maxAttempts {
            let state: DiskVolume
            do {
                state = try scanner.info(for: volume.deviceIdentifier)
            } catch {
                guard attempt == 0, volume.isMounted else {
                    throw error
                }
                state = volume
            }
            guard state.stableIdentity == volume.stableIdentity else {
                throw AppError(message: "Volume identity changed while unmounting \(volume.deviceIdentifier); refusing to unmount \(state.deviceIdentifier)")
            }
            lastMountedState = state
            if !state.isMounted {
                return
            }

            try mounter.unmount(deviceIdentifier: state.deviceIdentifier, mountPoint: state.mountPoint, force: true)

            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let refreshed: DiskVolume
                do {
                    refreshed = try scanner.info(for: volume.deviceIdentifier)
                } catch {
                    Log.warning("Unable to confirm \(volume.stableIdentity) unmounted through diskutil after unmount command; proceeding from command success: \(error.localizedDescription)")
                    return
                }
                guard refreshed.stableIdentity == volume.stableIdentity else {
                    throw AppError(message: "Volume identity changed while waiting for \(volume.deviceIdentifier) to unmount; refusing to continue")
                }
                lastMountedState = refreshed
                if !refreshed.isMounted {
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }

            if attempt < maxAttempts - 1 {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        let mountPoint = lastMountedState?.mountPoint ?? "(unknown)"
        throw AppError(message: "Volume \(volume.deviceIdentifier) stayed mounted at \(mountPoint) after force-unmount attempts")
    }
}
