import Foundation

public struct DiskDeviceGeometry {
    public let blockDevicePath: String
    public let sectorSize: UInt64
    public let totalSectors: UInt64
    public let partitionStartSector: UInt64?
    public let isWholeDisk: Bool
    public let isInternal: Bool?
    public let mediaReadOnly: Bool?

    public init(
        blockDevicePath: String,
        sectorSize: UInt64,
        totalSectors: UInt64,
        partitionStartSector: UInt64?,
        isWholeDisk: Bool,
        isInternal: Bool?,
        mediaReadOnly: Bool?
    ) {
        self.blockDevicePath = blockDevicePath
        self.sectorSize = sectorSize
        self.totalSectors = totalSectors
        self.partitionStartSector = partitionStartSector
        self.isWholeDisk = isWholeDisk
        self.isInternal = isInternal
        self.mediaReadOnly = mediaReadOnly
    }
}

public enum DevicePathResolver {
    public static func normalizedBlockDevicePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError(message: "Missing device argument")
        }

        let candidate: String
        if trimmed.hasPrefix("/dev/") {
            candidate = trimmed
        } else {
            candidate = "/dev/\(trimmed)"
        }

        guard candidate.hasPrefix("/dev/disk") || candidate.hasPrefix("/dev/rdisk") else {
            throw AppError(message: "Refusing to operate on non-disk device: \(trimmed)")
        }

        let blockCandidate: String
        if candidate.hasPrefix("/dev/rdisk") {
            blockCandidate = "/dev/disk" + candidate.dropFirst("/dev/rdisk".count)
        } else {
            blockCandidate = candidate
        }

        guard FileManager.default.fileExists(atPath: blockCandidate) else {
            throw AppError(message: "Device does not exist: \(blockCandidate)")
        }

        return blockCandidate
    }

    public static func preferredRawDevicePath(for blockDevicePath: String) -> String {
        guard blockDevicePath.hasPrefix("/dev/disk") else {
            return blockDevicePath
        }

        let suffix = String(blockDevicePath.dropFirst("/dev/disk".count))
        let rawPath = "/dev/rdisk\(suffix)"
        if FileManager.default.fileExists(atPath: rawPath) {
            return rawPath
        }

        return blockDevicePath
    }

    public static func diskGeometry(for raw: String) throws -> DiskDeviceGeometry {
        let blockDevicePath = try normalizedBlockDevicePath(raw)
        let result = try Shell.runChecked("/usr/sbin/diskutil", ["info", "-plist", blockDevicePath], timeout: 20)
        guard let plist = try parsePlistDictionary(from: result.stdout) else {
            throw AppError(message: "Unable to parse disk geometry for \(blockDevicePath)")
        }

        let sectorSize = numericValue(plist, key: "DeviceBlockSize") ?? 512
        guard sectorSize > 0 else {
            throw AppError(message: "Invalid sector size for \(blockDevicePath)")
        }

        let totalBytes =
            numericValue(plist, key: "Size")
            ?? numericValue(plist, key: "IOKitSize")
            ?? numericValue(plist, key: "TotalSize")
        guard let totalBytes, totalBytes >= sectorSize else {
            throw AppError(message: "Unable to determine device size for \(blockDevicePath)")
        }

        let totalSectors = totalBytes / sectorSize
        let isWholeDisk = boolValue(plist, key: "WholeDisk") ?? boolValue(plist, key: "Whole") ?? false
        let isInternal = boolValue(plist, key: "Internal") ?? boolValue(plist, key: "OSInternal")
        let mediaReadOnly = boolValue(plist, key: "MediaReadOnly")
        let partitionOffsetBytes = numericValue(plist, key: "PartitionMapPartitionOffset")
        let partitionStartSector: UInt64?
        if isWholeDisk {
            partitionStartSector = nil
        } else if let partitionOffsetBytes {
            partitionStartSector = partitionOffsetBytes / sectorSize
        } else {
            partitionStartSector = nil
        }

        return DiskDeviceGeometry(
            blockDevicePath: blockDevicePath,
            sectorSize: sectorSize,
            totalSectors: totalSectors,
            partitionStartSector: partitionStartSector,
            isWholeDisk: isWholeDisk,
            isInternal: isInternal,
            mediaReadOnly: mediaReadOnly
        )
    }

    public static func validateSafeFormatTarget(
        _ geometry: DiskDeviceGeometry,
        allowUnsafeTarget: Bool = false
    ) throws {
        if allowUnsafeTarget {
            return
        }

        guard geometry.blockDevicePath.range(of: #"^/dev/disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil else {
            throw AppError(message: "Refusing to format non-partition target \(geometry.blockDevicePath). Expected a partition such as /dev/disk13s2.")
        }
        guard geometry.isWholeDisk == false else {
            throw AppError(message: "Refusing to format whole disk \(geometry.blockDevicePath). Use a partition target such as /dev/disk13s2.")
        }
        guard geometry.isInternal == false else {
            throw AppError(message: "Refusing to format internal or unclassified device \(geometry.blockDevicePath).")
        }
        guard geometry.mediaReadOnly != true else {
            throw AppError(message: "Refusing to format read-only device \(geometry.blockDevicePath).")
        }
    }

    private static func parsePlistDictionary(from string: String) throws -> [String: Any]? {
        guard let data = string.data(using: .utf8) else {
            return nil
        }
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return object as? [String: Any]
    }

    private static func numericValue(_ dictionary: [String: Any], key: String) -> UInt64? {
        if let number = dictionary[key] as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    private static func boolValue(_ dictionary: [String: Any], key: String) -> Bool? {
        if let value = dictionary[key] as? Bool {
            return value
        }
        if let number = dictionary[key] as? NSNumber {
            return number.boolValue
        }
        return nil
    }
}
