import Foundation

@objcMembers
public final class OperationResultDTO: NSObject, NSSecureCoding {
    public static let supportsSecureCoding: Bool = true

    public let success: Bool
    public let message: String

    public init(success: Bool, message: String) {
        self.success = success
        self.message = message
    }

    public required init?(coder: NSCoder) {
        self.success = coder.decodeBool(forKey: "success")
        self.message = coder.decodeObject(of: NSString.self, forKey: "message") as String? ?? ""
    }

    public func encode(with coder: NSCoder) {
        coder.encode(success, forKey: "success")
        coder.encode(message, forKey: "message")
    }
}

@objcMembers
public final class VolumeStateDTO: NSObject, NSSecureCoding {
    public static let supportsSecureCoding: Bool = true

    public let deviceIdentifier: String
    public let stableIdentity: String
    public let parentWholeDisk: String
    public let parentWholeDiskName: String
    public let volumeName: String
    public let mountPoint: String
    public let isExternal: Bool
    public let modeRawValue: String
    public let reason: String
    public let lastTransitionAt: Date
    public let presentationStateRawValue: String
    public let statusColorRawValue: String
    public let primaryActionRawValue: String
    public let isActionable: Bool
    public let lastCheckedAt: Date

    public var mode: VolumeMode {
        VolumeMode(rawValue: modeRawValue) ?? .unmounted
    }

    public var presentationState: VolumePresentationStateRaw {
        VolumePresentationStateRaw(rawValue: presentationStateRawValue) ?? .failedToMount
    }

    public var statusColor: VolumeStatusColorRaw {
        VolumeStatusColorRaw(rawValue: statusColorRawValue) ?? .red
    }

    public var primaryAction: VolumeRecoveryActionRaw {
        VolumeRecoveryActionRaw(rawValue: primaryActionRawValue) ?? .none
    }

    public init(
        deviceIdentifier: String,
        stableIdentity: String? = nil,
        parentWholeDisk: String? = nil,
        parentWholeDiskName: String? = nil,
        volumeName: String,
        mountPoint: String,
        isExternal: Bool,
        mode: VolumeMode,
        reason: String,
        lastTransitionAt: Date,
        presentationState: VolumePresentationStateRaw? = nil,
        statusColor: VolumeStatusColorRaw? = nil,
        primaryAction: VolumeRecoveryActionRaw? = nil,
        isActionable: Bool? = nil,
        lastCheckedAt: Date? = nil
    ) {
        let derived = VolumeStateDTO.presentation(
            mode: mode,
            mountPoint: mountPoint,
            reason: reason
        )
        self.deviceIdentifier = deviceIdentifier
        self.stableIdentity = stableIdentity ?? deviceIdentifier
        self.parentWholeDisk = parentWholeDisk ?? ""
        self.parentWholeDiskName = parentWholeDiskName ?? ""
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.isExternal = isExternal
        self.modeRawValue = mode.rawValue
        self.reason = reason
        self.lastTransitionAt = lastTransitionAt
        self.presentationStateRawValue = (presentationState ?? derived.state).rawValue
        self.statusColorRawValue = (statusColor ?? derived.color).rawValue
        self.primaryActionRawValue = (primaryAction ?? derived.action).rawValue
        self.isActionable = isActionable ?? derived.action.isActionable
        self.lastCheckedAt = lastCheckedAt ?? lastTransitionAt
    }

    public required init?(coder: NSCoder) {
        self.deviceIdentifier = coder.decodeObject(of: NSString.self, forKey: "deviceIdentifier") as String? ?? ""
        self.stableIdentity = coder.decodeObject(of: NSString.self, forKey: "stableIdentity") as String? ?? self.deviceIdentifier
        self.parentWholeDisk = coder.decodeObject(of: NSString.self, forKey: "parentWholeDisk") as String? ?? ""
        self.parentWholeDiskName = coder.decodeObject(of: NSString.self, forKey: "parentWholeDiskName") as String? ?? ""
        self.volumeName = coder.decodeObject(of: NSString.self, forKey: "volumeName") as String? ?? ""
        self.mountPoint = coder.decodeObject(of: NSString.self, forKey: "mountPoint") as String? ?? ""
        self.isExternal = coder.decodeBool(forKey: "isExternal")
        self.modeRawValue = coder.decodeObject(of: NSString.self, forKey: "modeRawValue") as String? ?? VolumeMode.unmounted.rawValue
        self.reason = coder.decodeObject(of: NSString.self, forKey: "reason") as String? ?? ""
        self.lastTransitionAt = coder.decodeObject(of: NSDate.self, forKey: "lastTransitionAt") as Date? ?? Date()
        let mode = VolumeMode(rawValue: self.modeRawValue) ?? .unmounted
        let derived = VolumeStateDTO.presentation(
            mode: mode,
            mountPoint: self.mountPoint,
            reason: self.reason
        )
        self.presentationStateRawValue = coder.decodeObject(of: NSString.self, forKey: "presentationStateRawValue") as String? ?? derived.state.rawValue
        self.statusColorRawValue = coder.decodeObject(of: NSString.self, forKey: "statusColorRawValue") as String? ?? derived.color.rawValue
        self.primaryActionRawValue = coder.decodeObject(of: NSString.self, forKey: "primaryActionRawValue") as String? ?? derived.action.rawValue
        self.isActionable = coder.containsValue(forKey: "isActionable")
            ? coder.decodeBool(forKey: "isActionable")
            : derived.action.isActionable
        self.lastCheckedAt = coder.decodeObject(of: NSDate.self, forKey: "lastCheckedAt") as Date? ?? self.lastTransitionAt
    }

    public func encode(with coder: NSCoder) {
        coder.encode(deviceIdentifier, forKey: "deviceIdentifier")
        coder.encode(stableIdentity, forKey: "stableIdentity")
        coder.encode(parentWholeDisk, forKey: "parentWholeDisk")
        coder.encode(parentWholeDiskName, forKey: "parentWholeDiskName")
        coder.encode(volumeName, forKey: "volumeName")
        coder.encode(mountPoint, forKey: "mountPoint")
        coder.encode(isExternal, forKey: "isExternal")
        coder.encode(modeRawValue, forKey: "modeRawValue")
        coder.encode(reason, forKey: "reason")
        coder.encode(lastTransitionAt, forKey: "lastTransitionAt")
        coder.encode(presentationStateRawValue, forKey: "presentationStateRawValue")
        coder.encode(statusColorRawValue, forKey: "statusColorRawValue")
        coder.encode(primaryActionRawValue, forKey: "primaryActionRawValue")
        coder.encode(isActionable, forKey: "isActionable")
        coder.encode(lastCheckedAt, forKey: "lastCheckedAt")
    }

    private static func presentation(
        mode: VolumeMode,
        mountPoint: String,
        reason: String
    ) -> (state: VolumePresentationStateRaw, color: VolumeStatusColorRaw, action: VolumeRecoveryActionRaw) {
        let lowerReason = reason.lowercased()
        let hasReason = !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if containsAny(lowerReason, ["scan running", "scanning", "retrying", "repair queued", "mount in progress"]) {
            return (.scanning, .gray, .none)
        }
        if containsAny(lowerReason, ["device disconnected", "disconnected", "no longer attached", "unplugged"]) {
            return (.disconnected, .gray, .none)
        }
        if containsAny(lowerReason, ["user ejected", "ejected by user"]) {
            return (.ejected, .gray, .retryMount)
        }
        if containsAny(lowerReason, ["ignored", "unsupported non-ntfs", "non-ntfs"]) {
            return (.ignored, .gray, .none)
        }
        if containsAny(lowerReason, ["dirty", "hibernated", "unsafe", "windows cleanup", "windows fast startup", "encrypted", "bitlocker"]) {
            return (.unsafeNTFS, .red, .showWindowsCleanupGuidance)
        }
        if containsAny(lowerReason, ["macfuse", "fuse", "mount_macfuse"]) {
            return (.macFUSEUnavailable, .red, .showMacFUSEGuidance)
        }

        switch mode {
        case .readWrite:
            return hasReason
                ? (.readWriteWarning, .yellow, .rescan)
                : (.readWriteVerified, .green, .openInFinder)
        case .readOnly:
            if lowerReason.contains("native") || lowerReason.contains("macos read-only") || lowerReason.contains("macos native") {
                return (.nativeReadOnly, .yellow, .retryWritableTakeover)
            }
            if lowerReason.contains("ntfs access") || mountPoint.contains("NTFSAccess") || lowerReason.contains("fallback") {
                return (.readOnlyFallback, .yellow, .retryWritableTakeover)
            }
            if containsAny(lowerReason, ["operation not permitted", "raw access", "raw disk", "full disk access", "privacy"]) {
                return (.rawAccessDenied, .red, .openFullDiskAccess)
            }
            return (.nativeReadOnly, .yellow, .retryWritableTakeover)
        case .unmounted:
            if containsAny(lowerReason, ["operation not permitted", "raw access", "raw disk", "full disk access", "privacy"]) {
                return (.rawAccessDenied, .red, .openFullDiskAccess)
            }
            return (.failedToMount, .red, .retryMount)
        }
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

private extension VolumeRecoveryActionRaw {
    var isActionable: Bool {
        switch self {
        case .none, .openInFinder:
            return false
        case .rescan, .retryMount, .retryWritableTakeover, .openFullDiskAccess, .showMacFUSEGuidance, .showWindowsCleanupGuidance:
            return true
        }
    }
}

@objcMembers
public final class ServiceStateDTO: NSObject, NSSecureCoding {
    public static let supportsSecureCoding: Bool = true

    public let healthRawValue: String
    public let managedVolumeCount: Int
    public let degradedVolumeCount: Int
    public let lastError: String
    public let updatedAt: Date
    public let notificationsEnabled: Bool
    public let durabilityModeRawValue: String
    public let warningCount: Int
    public let lastWarning: String
    public let operationRawValue: String
    public let operationStartedAt: Date?
    public let operationMessage: String

    public var health: ServiceHealth {
        ServiceHealth(rawValue: healthRawValue) ?? .error
    }

    public var durabilityMode: MountDurabilityModeRaw {
        MountDurabilityModeRaw(rawValue: durabilityModeRawValue) ?? .performance
    }

    public var operation: ServiceOperationRaw {
        ServiceOperationRaw(rawValue: operationRawValue) ?? .idle
    }

    public init(
        health: ServiceHealth,
        managedVolumeCount: Int,
        degradedVolumeCount: Int,
        lastError: String,
        updatedAt: Date,
        notificationsEnabled: Bool,
        durabilityModeRawValue: String = MountDurabilityModeRaw.performance.rawValue,
        warningCount: Int = 0,
        lastWarning: String = "",
        operation: ServiceOperationRaw = .idle,
        operationStartedAt: Date? = nil,
        operationMessage: String = ""
    ) {
        self.healthRawValue = health.rawValue
        self.managedVolumeCount = managedVolumeCount
        self.degradedVolumeCount = degradedVolumeCount
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.notificationsEnabled = notificationsEnabled
        self.durabilityModeRawValue = durabilityModeRawValue
        self.warningCount = warningCount
        self.lastWarning = lastWarning
        self.operationRawValue = operation.rawValue
        self.operationStartedAt = operationStartedAt
        self.operationMessage = operationMessage
    }

    public required init?(coder: NSCoder) {
        self.healthRawValue = coder.decodeObject(of: NSString.self, forKey: "healthRawValue") as String? ?? ServiceHealth.error.rawValue
        self.managedVolumeCount = coder.decodeInteger(forKey: "managedVolumeCount")
        self.degradedVolumeCount = coder.decodeInteger(forKey: "degradedVolumeCount")
        self.lastError = coder.decodeObject(of: NSString.self, forKey: "lastError") as String? ?? ""
        self.updatedAt = coder.decodeObject(of: NSDate.self, forKey: "updatedAt") as Date? ?? Date()
        self.notificationsEnabled = coder.decodeBool(forKey: "notificationsEnabled")
        self.durabilityModeRawValue = coder.decodeObject(of: NSString.self, forKey: "durabilityModeRawValue") as String? ?? MountDurabilityModeRaw.performance.rawValue
        self.warningCount = coder.decodeInteger(forKey: "warningCount")
        self.lastWarning = coder.decodeObject(of: NSString.self, forKey: "lastWarning") as String? ?? ""
        self.operationRawValue = coder.decodeObject(of: NSString.self, forKey: "operationRawValue") as String? ?? ServiceOperationRaw.idle.rawValue
        self.operationStartedAt = coder.decodeObject(of: NSDate.self, forKey: "operationStartedAt") as Date?
        self.operationMessage = coder.decodeObject(of: NSString.self, forKey: "operationMessage") as String? ?? ""
    }

    public func encode(with coder: NSCoder) {
        coder.encode(healthRawValue, forKey: "healthRawValue")
        coder.encode(managedVolumeCount, forKey: "managedVolumeCount")
        coder.encode(degradedVolumeCount, forKey: "degradedVolumeCount")
        coder.encode(lastError, forKey: "lastError")
        coder.encode(updatedAt, forKey: "updatedAt")
        coder.encode(notificationsEnabled, forKey: "notificationsEnabled")
        coder.encode(durabilityModeRawValue, forKey: "durabilityModeRawValue")
        coder.encode(warningCount, forKey: "warningCount")
        coder.encode(lastWarning, forKey: "lastWarning")
        coder.encode(operationRawValue, forKey: "operationRawValue")
        coder.encode(operationStartedAt, forKey: "operationStartedAt")
        coder.encode(operationMessage, forKey: "operationMessage")
    }
}
