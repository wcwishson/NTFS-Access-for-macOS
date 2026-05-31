import Foundation

public enum XPCConstants {
    public static let machServiceName = "com.ntfsaccess.mountd"
}

public enum ServiceHealth: String, CaseIterable, Sendable {
    case healthy
    case warning
    case degradedReadOnly = "degraded_read_only"
    case unavailable
    case error
}

public enum VolumeMode: String, CaseIterable, Sendable {
    case readWrite
    case readOnly
    case unmounted
}

public enum MountDurabilityModeRaw: String, CaseIterable, Sendable {
    case performance
    case conservative
}

public enum VolumePresentationStateRaw: String, CaseIterable, Sendable {
    case readWriteVerified
    case readWriteWarning
    case readOnlyFallback
    case nativeReadOnly
    case failedToMount
    case rawAccessDenied
    case macFUSEUnavailable
    case unsafeNTFS
    case scanning
    case disconnected
    case ejected
    case ignored
}

public enum VolumeStatusColorRaw: String, CaseIterable, Sendable {
    case green
    case yellow
    case red
    case gray
}

public enum VolumeRecoveryActionRaw: String, CaseIterable, Sendable {
    case none
    case openInFinder
    case rescan
    case retryMount
    case retryWritableTakeover
    case openFullDiskAccess
    case showMacFUSEGuidance
    case showWindowsCleanupGuidance
}

public enum ServiceOperationRaw: String, CaseIterable, Sendable {
    case idle
    case scanning
    case repairing
}
