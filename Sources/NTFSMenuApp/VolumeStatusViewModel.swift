import AppKit
import Foundation
import NTFSAccessShared

enum VolumeStatusColor: String, Sendable {
    case green
    case yellow
    case red
    case gray
}

struct VolumeStatusRow: Identifiable, Sendable {
    let id: String
    let stableIdentity: String
    let deviceIdentifier: String
    let parentWholeDisk: String
    let parentWholeDiskName: String
    let volumeName: String
    let mountPoint: String
    let modeRawValue: String
    let reason: String
    let lastCheckedAt: Date
    let statusColor: VolumeStatusColor
    let presentationState: VolumePresentationStateRaw
    let primaryAction: VolumeRecoveryActionRaw
    let isActionable: Bool

    var displayName: String {
        if !volumeName.isEmpty {
            return volumeName
        }

        return deviceIdentifier.isEmpty ? "Unknown NTFS volume" : deviceIdentifier
    }

    var driveDisplayName: String {
        if !parentWholeDiskName.isEmpty {
            return parentWholeDiskName
        }
        if !parentWholeDisk.isEmpty {
            return parentWholeDisk
        }
        return "External NTFS Drive"
    }

    var driveGroupTitle: String {
        let name = driveDisplayName
        if name == parentWholeDisk || parentWholeDisk.isEmpty {
            return name
        }
        return "\(name) (\(parentWholeDisk))"
    }

    var driveSortKey: String {
        if !parentWholeDisk.isEmpty {
            return parentWholeDisk
        }
        return driveDisplayName
    }

    var modeLabel: String {
        switch presentationState {
        case .readWriteVerified:
            return "Read/write"
        case .readWriteWarning:
            return "Read/write warning"
        case .readOnlyFallback:
            return "Read-only fallback"
        case .nativeReadOnly:
            return "macOS read-only"
        case .failedToMount:
            return "Failed to mount"
        case .rawAccessDenied:
            return "Full Disk Access refresh needed"
        case .macFUSEUnavailable:
            return "macFUSE unavailable"
        case .unsafeNTFS:
            return "Windows cleanup needed"
        case .ejected:
            return "Ejected"
        case .scanning:
            return "Scanning"
        case .disconnected:
            return "Disconnected"
        case .ignored:
            return "Ignored"
        }
    }

    var isFixEnabled: Bool {
        isActionable
    }

    var fixButtonTitle: String {
        return "Fix"
    }

    var mountPointLabel: String {
        mountPoint.isEmpty ? "No mount point" : mountPoint
    }

    var reasonLabel: String {
        reason.isEmpty ? "" : reason
    }

    init(dto: VolumeStateDTO) {
        self.id = dto.stableIdentity.isEmpty ? dto.deviceIdentifier : dto.stableIdentity
        self.stableIdentity = dto.stableIdentity
        self.deviceIdentifier = dto.deviceIdentifier
        self.parentWholeDisk = dto.parentWholeDisk
        self.parentWholeDiskName = dto.parentWholeDiskName
        self.volumeName = dto.volumeName
        self.mountPoint = dto.mountPoint
        self.modeRawValue = dto.modeRawValue
        self.reason = dto.reason
        self.lastCheckedAt = dto.lastCheckedAt
        self.statusColor = VolumeStatusColor(rawValue: dto.statusColor.rawValue) ?? .red
        self.presentationState = dto.presentationState
        self.primaryAction = dto.primaryAction
        self.isActionable = dto.isActionable
    }
}

struct DashboardSnapshot: Sendable {
    let rows: [VolumeStatusRow]
    let serviceHealth: ServiceHealth
    let serviceMessage: String
    let isLoading: Bool
    let operationMessage: String
    let operation: ServiceOperationRaw
    let updatedAt: Date?

    static let initial = DashboardSnapshot(
        rows: [],
        serviceHealth: .unavailable,
        serviceMessage: "Checking NTFS Access...",
        isLoading: false,
        operationMessage: "",
        operation: .idle,
        updatedAt: nil
    )
}

@MainActor
final class VolumeStatusViewModel {
    var onChange: ((DashboardSnapshot) -> Void)?

    private let xpcClient: XPCClient
    private var snapshot = DashboardSnapshot.initial

    init(xpcClient: XPCClient = XPCClient()) {
        self.xpcClient = xpcClient
    }

    func refresh() {
        update(isLoading: true, operationMessage: "Refreshing...")

        xpcClient.getServiceState { [weak self] serviceResult in
            Task { @MainActor [weak self] in
                switch serviceResult {
                case .success(let dto):
                    let serviceSnapshot = ServiceDashboardSnapshot(dto: dto)
                    self?.refreshVolumes(serviceSnapshot: serviceSnapshot)
                case .failure(let error):
                    let serviceSnapshot = ServiceDashboardSnapshot(
                        health: .unavailable,
                        message: error.localizedDescription
                    )
                    self?.refreshVolumes(serviceSnapshot: serviceSnapshot)
                }
            }
        }
    }

    func rescan() {
        update(isLoading: true, operationMessage: "Requesting rescan...")
        xpcClient.scanNow { [weak self] result in
            let message = Self.operationMessage(prefix: "Rescan", result: result)
            Task { @MainActor [weak self] in
                self?.update(operationMessage: message)
                self?.refresh()
            }
        }
    }

    func fix(row: VolumeStatusRow) {
        guard row.isFixEnabled else {
            return
        }

        if row.primaryAction == .openFullDiskAccess {
            openFullDiskAccessSettings()
        }

        update(isLoading: true, operationMessage: "Running \(row.fixButtonTitle.lowercased()) for \(row.displayName)...")
        xpcClient.repairVolume(stableIdentity: row.stableIdentity, action: row.primaryAction) { [weak self] result in
            let message = Self.operationMessage(prefix: "Fix", result: result)
            Task { @MainActor [weak self] in
                self?.update(operationMessage: message)
                self?.refresh()
            }
        }
    }

    func openInFinder(row: VolumeStatusRow) {
        guard !row.mountPoint.isEmpty else {
            update(operationMessage: "No mount point is available for \(row.displayName).")
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: row.mountPoint))
    }

    func eject(row: VolumeStatusRow) {
        update(isLoading: true, operationMessage: "Ejecting \(row.displayName)...")
        xpcClient.ejectVolume(stableIdentity: row.stableIdentity) { [weak self] result in
            let message = Self.operationMessage(prefix: "Eject", result: result)
            Task { @MainActor [weak self] in
                self?.update(operationMessage: message)
                self?.refresh()
            }
        }
    }

    func detailsMessage(for row: VolumeStatusRow) -> String {
        """
        Volume: \(row.displayName)
        Physical drive: \(row.driveGroupTitle)
        Device: \(row.deviceIdentifier)
        Mount point: \(row.mountPointLabel)
        Status: \(row.modeLabel)
        Last checked: \(Self.dateFormatter.string(from: row.lastCheckedAt))

        \(row.reasonLabel)

        \(Self.guidanceMessage(for: row.primaryAction))
        """
    }

    func guidanceMessage(for row: VolumeStatusRow) -> String {
        Self.guidanceMessage(for: row.primaryAction)
    }

    private func refreshVolumes(serviceSnapshot: ServiceDashboardSnapshot) {
        xpcClient.getVolumeStates { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .success(let dtos):
                    let rows = dtos
                        .filter(\.isExternal)
                        .map(VolumeStatusRow.init(dto:))
                        .sorted { lhs, rhs in
                            if lhs.driveSortKey != rhs.driveSortKey {
                                return lhs.driveSortKey.localizedStandardCompare(rhs.driveSortKey) == .orderedAscending
                            }
                            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                        }
                    self?.update(
                        rows: rows,
                        serviceHealth: serviceSnapshot.health,
                        serviceMessage: serviceSnapshot.message,
                        isLoading: serviceSnapshot.operation != .idle,
                        operationMessage: serviceSnapshot.userFacingOperationMessage.isEmpty
                            ? (rows.isEmpty ? "No external NTFS drives connected." : "")
                            : serviceSnapshot.userFacingOperationMessage,
                        operation: serviceSnapshot.operation,
                        updatedAt: Date()
                    )
                case .failure(let error):
                    self?.update(
                        rows: [],
                        serviceHealth: serviceSnapshot.health,
                        serviceMessage: error.localizedDescription,
                        isLoading: false,
                        operationMessage: "No external NTFS drives connected.",
                        operation: .idle,
                        updatedAt: Date()
                    )
                }
            }
        }
    }

    private func update(
        rows: [VolumeStatusRow]? = nil,
        serviceHealth: ServiceHealth? = nil,
        serviceMessage: String? = nil,
        isLoading: Bool? = nil,
        operationMessage: String? = nil,
        operation: ServiceOperationRaw? = nil,
        updatedAt: Date? = nil
    ) {
        snapshot = DashboardSnapshot(
            rows: rows ?? snapshot.rows,
            serviceHealth: serviceHealth ?? snapshot.serviceHealth,
            serviceMessage: serviceMessage ?? snapshot.serviceMessage,
            isLoading: isLoading ?? snapshot.isLoading,
            operationMessage: operationMessage ?? snapshot.operationMessage,
            operation: operation ?? snapshot.operation,
            updatedAt: updatedAt ?? snapshot.updatedAt
        )
        onChange?(snapshot)
    }

    private static func operationMessage(prefix: String, result: Result<OperationResultDTO, Error>) -> String {
        switch result {
        case .success(let dto):
            return dto.message.isEmpty ? "\(prefix) requested." : dto.message
        case .failure(let error):
            return "\(prefix) failed: \(error.localizedDescription)"
        }
    }

    private static func guidanceMessage(for action: VolumeRecoveryActionRaw) -> String {
        switch action {
        case .openFullDiskAccess:
            return "Full Disk Access is macOS' privacy gate for raw disks. If NTFS Access is already enabled, remove it from the list, add /Applications/NTFS Access.app again, then retry. Development rebuilds can make macOS treat the app like a new privacy identity."
        case .showMacFUSEGuidance:
            return "macFUSE is the compatibility layer NTFS Access uses to present a writable NTFS volume to Finder. Approve or reinstall macFUSE, then retry."
        case .showWindowsCleanupGuidance:
            return "Windows cleanup is required before writing. Fully shut Windows down, disable hibernation or Fast Startup, or run chkdsk."
        case .rescan:
            return "The daemon will rescan the drive and refresh this status."
        case .retryMount:
            return "The daemon will mount this NTFS partition again if it is safe and available."
        case .retryWritableTakeover:
            return "The daemon will retry taking over the read-only mount with NTFS Access. It will not write to unsafe NTFS."
        case .openInFinder:
            return "This volume is mounted and can be opened in Finder."
        case .none:
            return "No recovery action is available for this state."
        }
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct ServiceDashboardSnapshot: Sendable {
    let health: ServiceHealth
    let message: String
    let operation: ServiceOperationRaw
    let operationMessage: String

    var userFacingOperationMessage: String {
        switch operationMessage {
        case "interval", "startup", "coalesced", "disk appeared", "disk disappeared", "disk changed":
            return ""
        default:
            return operationMessage
        }
    }

    init(dto: ServiceStateDTO) {
        self.health = dto.health
        self.message = dto.lastError.isEmpty ? dto.lastWarning : dto.lastError
        self.operation = dto.operation
        self.operationMessage = dto.operationMessage
    }

    init(health: ServiceHealth, message: String) {
        self.health = health
        self.message = message
        self.operation = .idle
        self.operationMessage = ""
    }
}
