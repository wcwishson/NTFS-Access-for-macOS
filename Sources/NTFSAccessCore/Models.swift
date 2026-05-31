import Foundation
import NTFSAccessShared

public struct DependencyReport {
    public let operatingSystem: String
    public let architecture: String
    public let ntfs3gPath: String?
    public let ntfs3gProbePath: String?
    public let mkntfsPath: String?
    public let ntfsfixPath: String?
    public let ntfslabelPath: String?
    public let macFUSEHelperPath: String?
    public let formatterBundlePath: String?
    public let formatterBundleInstalled: Bool
    public let formatterPersonalityRegistered: Bool
    public let formatterProbeOrders: [String: Int]
    public let ntfsFormatterPersonalityName: String
    public let detectedNTFSPersonalities: [String]
    public let installedAppSignatureDescription: String
    public let runningMountDaemonProgram: String?
    public let runningMountDaemonSignatureDescription: String
    public let installedMountWrapperUsesAppHelper: Bool
    public let mountIssues: [String]
    public let formatIssues: [String]
    public let advisoryNotes: [String]

    public var isHealthy: Bool {
        mountIssues.isEmpty && formatIssues.isEmpty
    }

    public var issues: [String] {
        mountIssues + formatIssues
    }

    public var mountReady: Bool {
        mountIssues.isEmpty
    }

    public var formatReady: Bool {
        formatIssues.isEmpty
    }
}

public enum MountDurabilityMode: String, Codable, CaseIterable, Sendable {
    case performance
    case conservative

    public var sharedRawValue: String {
        rawValue
    }

    public init(sharedRawValue: String) {
        self = MountDurabilityMode(rawValue: sharedRawValue) ?? .performance
    }
}

public struct DaemonSettings: Codable, Equatable, Sendable {
    public var notificationsEnabled: Bool
    public var durabilityMode: MountDurabilityMode

    public init(
        notificationsEnabled: Bool = true,
        durabilityMode: MountDurabilityMode = .performance
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.durabilityMode = durabilityMode
    }
}

public struct DiskVolume: Equatable {
    public let deviceIdentifier: String
    public let deviceNode: String
    public let stableIdentity: String
    public let volumeUUID: String?
    public let diskUUID: String?
    public let mediaUUID: String?
    public let parentWholeDisk: String?
    public let parentWholeDiskName: String?
    public let partitionMapPartitionOffset: Int64?
    public let size: Int64?
    public let volumeName: String
    public let mediaName: String
    public let filesystemType: String?
    public let filesystemName: String?
    public let mountPoint: String?
    public let isMounted: Bool
    public let isWritable: Bool
    public let isInternal: Bool

    public init(
        deviceIdentifier: String,
        deviceNode: String,
        stableIdentity: String? = nil,
        volumeUUID: String? = nil,
        diskUUID: String? = nil,
        mediaUUID: String? = nil,
        parentWholeDisk: String? = nil,
        parentWholeDiskName: String? = nil,
        partitionMapPartitionOffset: Int64? = nil,
        size: Int64? = nil,
        volumeName: String,
        mediaName: String,
        filesystemType: String?,
        filesystemName: String?,
        mountPoint: String?,
        isMounted: Bool,
        isWritable: Bool,
        isInternal: Bool
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.deviceNode = deviceNode
        self.volumeUUID = volumeUUID
        self.diskUUID = diskUUID
        self.mediaUUID = mediaUUID
        self.parentWholeDisk = parentWholeDisk
        self.parentWholeDiskName = parentWholeDiskName
        self.partitionMapPartitionOffset = partitionMapPartitionOffset
        self.size = size
        self.stableIdentity = stableIdentity ?? DiskVolume.makeStableIdentity(
            deviceIdentifier: deviceIdentifier,
            volumeUUID: volumeUUID,
            diskUUID: diskUUID,
            mediaUUID: mediaUUID,
            volumeName: volumeName,
            filesystemType: filesystemType,
            partitionMapPartitionOffset: partitionMapPartitionOffset,
            size: size
        )
        self.volumeName = volumeName
        self.mediaName = mediaName
        self.filesystemType = filesystemType
        self.filesystemName = filesystemName
        self.mountPoint = mountPoint
        self.isMounted = isMounted
        self.isWritable = isWritable
        self.isInternal = isInternal
    }

    private static func makeStableIdentity(
        deviceIdentifier: String,
        volumeUUID: String?,
        diskUUID: String?,
        mediaUUID: String?,
        volumeName: String,
        filesystemType: String?,
        partitionMapPartitionOffset: Int64?,
        size: Int64?
    ) -> String {
        if let value = normalizedIdentityValue(volumeUUID) {
            return "volumeuuid-\(value)"
        }
        if let value = normalizedIdentityValue(diskUUID) {
            return "diskuuid-\(value)"
        }
        if let value = normalizedIdentityValue(mediaUUID) {
            return "mediauuid-\(value)"
        }
        if let offset = partitionMapPartitionOffset, let size {
            return "layout-\(normalizedIdentityComponent(volumeName))-\(offset)-\(size)"
        }
        return deviceIdentifier
    }

    private static func normalizedIdentityValue(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : normalizedIdentityComponent(value)
    }

    private static func normalizedIdentityComponent(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let cleaned = String(raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    public var isNTFS: Bool {
        let loweredType = filesystemType?.lowercased()
        let loweredName = filesystemName?.lowercased()
        let typeMatch = loweredType == "ntfs" || loweredType == "ntfsaccess"
        let nameMatch = loweredName?.contains("ntfs") == true
        return typeMatch || nameMatch
    }

    public var isExternal: Bool {
        !isInternal
    }

    public var isManagedByNTFSAccessBundle: Bool {
        filesystemType?.lowercased() == "ntfsaccess" || filesystemName?.lowercased().contains("ntfs access") == true
    }

    public func copyForMountState(
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

    public func copyWithStableIdentity(_ stableIdentity: String) -> DiskVolume {
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

    public func mergingPhysicalDriveMetadata(from fallback: DiskVolume) -> DiskVolume {
        mergingPhysicalDriveMetadata(
            parentWholeDisk: fallback.parentWholeDisk,
            parentWholeDiskName: fallback.parentWholeDiskName
        )
    }

    public func mergingPhysicalDriveMetadata(
        parentWholeDisk fallbackParentWholeDisk: String?,
        parentWholeDiskName fallbackParentWholeDiskName: String?
    ) -> DiskVolume {
        DiskVolume(
            deviceIdentifier: deviceIdentifier,
            deviceNode: deviceNode,
            stableIdentity: stableIdentity,
            volumeUUID: volumeUUID,
            diskUUID: diskUUID,
            mediaUUID: mediaUUID,
            parentWholeDisk: Self.nonEmpty(parentWholeDisk) ?? Self.nonEmpty(fallbackParentWholeDisk),
            parentWholeDiskName: Self.mergedWholeDiskName(
                currentName: parentWholeDiskName,
                currentWholeDisk: parentWholeDisk,
                fallbackName: fallbackParentWholeDiskName
            ),
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

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func mergedWholeDiskName(
        currentName: String?,
        currentWholeDisk: String?,
        fallbackName: String?
    ) -> String? {
        let current = nonEmpty(currentName)
        let fallback = nonEmpty(fallbackName)
        if current == nonEmpty(currentWholeDisk), let fallback {
            return fallback
        }
        return current ?? fallback
    }
}

public struct ManagedVolumeState {
    public let deviceIdentifier: String
    public let stableIdentity: String
    public let parentWholeDisk: String
    public let parentWholeDiskName: String
    public let volumeName: String
    public let mountPoint: String
    public let isExternal: Bool
    public let mode: VolumeMode
    public let reason: String
    public let lastTransitionAt: Date

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
        lastTransitionAt: Date
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.stableIdentity = stableIdentity ?? deviceIdentifier
        self.parentWholeDisk = parentWholeDisk ?? ""
        self.parentWholeDiskName = parentWholeDiskName ?? ""
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.isExternal = isExternal
        self.mode = mode
        self.reason = reason
        self.lastTransitionAt = lastTransitionAt
    }

    public init(
        volume: DiskVolume,
        mountPoint: String? = nil,
        mode: VolumeMode,
        reason: String,
        lastTransitionAt: Date
    ) {
        self.init(
            deviceIdentifier: volume.deviceIdentifier,
            stableIdentity: volume.stableIdentity,
            parentWholeDisk: volume.parentWholeDisk,
            parentWholeDiskName: volume.parentWholeDiskName,
            volumeName: volume.volumeName,
            mountPoint: mountPoint ?? volume.mountPoint ?? "",
            isExternal: volume.isExternal,
            mode: mode,
            reason: reason,
            lastTransitionAt: lastTransitionAt
        )
    }

    public func toDTO() -> VolumeStateDTO {
        VolumeStateDTO(
            deviceIdentifier: deviceIdentifier,
            stableIdentity: stableIdentity,
            parentWholeDisk: parentWholeDisk,
            parentWholeDiskName: parentWholeDiskName,
            volumeName: volumeName,
            mountPoint: mountPoint,
            isExternal: isExternal,
            mode: mode,
            reason: reason,
            lastTransitionAt: lastTransitionAt
        )
    }
}

public struct ReconcileResult {
    public let volumes: [ManagedVolumeState]
    public let health: ServiceHealth
    public let lastError: String
    public let managedVolumeCount: Int
    public let degradedVolumeCount: Int
    public let warningCount: Int
    public let lastWarning: String

    public init(
        volumes: [ManagedVolumeState],
        health: ServiceHealth,
        lastError: String,
        managedVolumeCount: Int,
        degradedVolumeCount: Int,
        warningCount: Int = 0,
        lastWarning: String = ""
    ) {
        self.volumes = volumes
        self.health = health
        self.lastError = lastError
        self.managedVolumeCount = managedVolumeCount
        self.degradedVolumeCount = degradedVolumeCount
        self.warningCount = warningCount
        self.lastWarning = lastWarning
    }

    public func serviceState(notificationsEnabled: Bool) -> ServiceStateDTO {
        serviceState(
            notificationsEnabled: notificationsEnabled,
            durabilityMode: .performance
        )
    }

    public func serviceState(
        notificationsEnabled: Bool,
        durabilityMode: MountDurabilityMode
    ) -> ServiceStateDTO {
        ServiceStateDTO(
            health: health,
            managedVolumeCount: managedVolumeCount,
            degradedVolumeCount: degradedVolumeCount,
            lastError: lastError,
            updatedAt: Date(),
            notificationsEnabled: notificationsEnabled,
            durabilityModeRawValue: durabilityMode.sharedRawValue,
            warningCount: warningCount,
            lastWarning: lastWarning
        )
    }
}

public struct DaemonConfiguration {
    public let mountRoot: String
    public let scanIntervalSeconds: TimeInterval
    public let manageExternalOnly: Bool
    public let attemptNativeReadOnlyTakeover: Bool

    public init(
        mountRoot: String = "/Volumes",
        scanIntervalSeconds: TimeInterval = 3,
        manageExternalOnly: Bool = true,
        attemptNativeReadOnlyTakeover: Bool = false
    ) {
        self.mountRoot = mountRoot
        self.scanIntervalSeconds = max(1, scanIntervalSeconds)
        self.manageExternalOnly = manageExternalOnly
        self.attemptNativeReadOnlyTakeover = attemptNativeReadOnlyTakeover
    }
}

public enum NTFSAccessPaths {
    public static let appBundlePath = "/Applications/NTFS Access.app"
    public static let appBundledToolchainRootPath = "\(appBundlePath)/Contents/Library/NTFSAccess/toolchain"
    public static let appBundledToolchainBinPath = "\(appBundledToolchainRootPath)/bin"
    public static let appBundledToolchainSbinPath = "\(appBundledToolchainRootPath)/sbin"
    public static let appBundledToolchainLibPath = "\(appBundledToolchainRootPath)/lib"
    public static let supportDirectoryPath = "/Library/Application Support/NTFSAccess"
    public static let daemonSettingsPath = "\(supportDirectoryPath)/daemon-settings.plist"
    public static let managedToolchainRootPath = "/Library/NTFSAccess/toolchain"
    public static let managedToolchainBinPath = "\(managedToolchainRootPath)/bin"
    public static let managedToolchainSbinPath = "\(managedToolchainRootPath)/sbin"
    public static let formatterBundleName = "ntfsaccess.fs"
    public static let formatterBundlePath = "/Library/Filesystems/\(formatterBundleName)"
    public static let formatterInfoPlistPath = "\(formatterBundlePath)/Contents/Info.plist"
    public static let formatterResourcesPath = "\(formatterBundlePath)/Contents/Resources"
    public static let formatterPersonalityName = "NTFS Access"
    public static let formatterUserVisibleName = "Windows NT File System (NTFS Access)"
}
