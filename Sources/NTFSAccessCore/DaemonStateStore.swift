import Foundation
import NTFSAccessShared

public final class DaemonStateStore {
    private let queue = DispatchQueue(label: "com.ntfsaccess.mountd.state")

    private var serviceState = ServiceStateDTO(
        health: .unavailable,
        managedVolumeCount: 0,
        degradedVolumeCount: 0,
        lastError: "service starting",
        updatedAt: Date(),
        notificationsEnabled: true,
        durabilityModeRawValue: MountDurabilityMode.performance.sharedRawValue
    )

    private var volumeStates: [String: VolumeStateDTO] = [:]
    private var durabilityMode: MountDurabilityMode = .performance

    public init(notificationsEnabled: Bool = true, durabilityMode: MountDurabilityMode = .performance) {
        self.durabilityMode = durabilityMode
        serviceState = ServiceStateDTO(
            health: .unavailable,
            managedVolumeCount: 0,
            degradedVolumeCount: 0,
            lastError: "service starting",
            updatedAt: Date(),
            notificationsEnabled: notificationsEnabled,
            durabilityModeRawValue: durabilityMode.sharedRawValue
        )
    }

    public func update(from result: ReconcileResult) {
        queue.sync {
            let notificationsEnabled = serviceState.notificationsEnabled
            let currentOperation = serviceState.operation
            let currentOperationStartedAt = serviceState.operationStartedAt
            let currentOperationMessage = serviceState.operationMessage
            serviceState = result.serviceState(
                notificationsEnabled: notificationsEnabled,
                durabilityMode: durabilityMode
            )
            if currentOperation != .idle {
                serviceState = ServiceStateDTO(
                    health: serviceState.health,
                    managedVolumeCount: serviceState.managedVolumeCount,
                    degradedVolumeCount: serviceState.degradedVolumeCount,
                    lastError: serviceState.lastError,
                    updatedAt: serviceState.updatedAt,
                    notificationsEnabled: serviceState.notificationsEnabled,
                    durabilityModeRawValue: serviceState.durabilityModeRawValue,
                    warningCount: serviceState.warningCount,
                    lastWarning: serviceState.lastWarning,
                    operation: currentOperation,
                    operationStartedAt: currentOperationStartedAt,
                    operationMessage: currentOperationMessage
                )
            }

            var map: [String: VolumeStateDTO] = [:]
            for volume in result.volumes {
                map[volume.stableIdentity] = volume.toDTO()
            }
            volumeStates = map
        }
    }

    public func markError(_ message: String) {
        queue.sync {
            serviceState = ServiceStateDTO(
                health: .error,
                managedVolumeCount: serviceState.managedVolumeCount,
                degradedVolumeCount: serviceState.degradedVolumeCount,
                lastError: message,
                updatedAt: Date(),
                notificationsEnabled: serviceState.notificationsEnabled,
                durabilityModeRawValue: durabilityMode.sharedRawValue,
                warningCount: serviceState.warningCount,
                lastWarning: serviceState.lastWarning,
                operation: serviceState.operation,
                operationStartedAt: serviceState.operationStartedAt,
                operationMessage: serviceState.operationMessage
            )
        }
    }

    public func setNotificationsEnabled(_ enabled: Bool) {
        queue.sync {
            serviceState = ServiceStateDTO(
                health: serviceState.health,
                managedVolumeCount: serviceState.managedVolumeCount,
                degradedVolumeCount: serviceState.degradedVolumeCount,
                lastError: serviceState.lastError,
                updatedAt: Date(),
                notificationsEnabled: enabled,
                durabilityModeRawValue: durabilityMode.sharedRawValue,
                warningCount: serviceState.warningCount,
                lastWarning: serviceState.lastWarning,
                operation: serviceState.operation,
                operationStartedAt: serviceState.operationStartedAt,
                operationMessage: serviceState.operationMessage
            )
        }
    }

    public func setDurabilityMode(_ mode: MountDurabilityMode) {
        queue.sync {
            durabilityMode = mode
            serviceState = ServiceStateDTO(
                health: serviceState.health,
                managedVolumeCount: serviceState.managedVolumeCount,
                degradedVolumeCount: serviceState.degradedVolumeCount,
                lastError: serviceState.lastError,
                updatedAt: Date(),
                notificationsEnabled: serviceState.notificationsEnabled,
                durabilityModeRawValue: mode.sharedRawValue,
                warningCount: serviceState.warningCount,
                lastWarning: serviceState.lastWarning,
                operation: serviceState.operation,
                operationStartedAt: serviceState.operationStartedAt,
                operationMessage: serviceState.operationMessage
            )
        }
    }

    public func beginOperation(_ operation: ServiceOperationRaw, message: String) {
        queue.sync {
            serviceState = ServiceStateDTO(
                health: serviceState.health,
                managedVolumeCount: serviceState.managedVolumeCount,
                degradedVolumeCount: serviceState.degradedVolumeCount,
                lastError: serviceState.lastError,
                updatedAt: Date(),
                notificationsEnabled: serviceState.notificationsEnabled,
                durabilityModeRawValue: durabilityMode.sharedRawValue,
                warningCount: serviceState.warningCount,
                lastWarning: serviceState.lastWarning,
                operation: operation,
                operationStartedAt: Date(),
                operationMessage: message
            )
        }
    }

    public func finishOperation(message: String = "") {
        queue.sync {
            serviceState = ServiceStateDTO(
                health: serviceState.health,
                managedVolumeCount: serviceState.managedVolumeCount,
                degradedVolumeCount: serviceState.degradedVolumeCount,
                lastError: serviceState.lastError,
                updatedAt: Date(),
                notificationsEnabled: serviceState.notificationsEnabled,
                durabilityModeRawValue: durabilityMode.sharedRawValue,
                warningCount: serviceState.warningCount,
                lastWarning: serviceState.lastWarning,
                operation: .idle,
                operationStartedAt: nil,
                operationMessage: message
            )
        }
    }

    public func currentServiceState() -> ServiceStateDTO {
        queue.sync { serviceState }
    }

    public func currentVolumeStates() -> [VolumeStateDTO] {
        queue.sync { volumeStates.values.sorted { $0.stableIdentity < $1.stableIdentity } }
    }
}
