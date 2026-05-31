import Foundation

public struct NTFSPartitionRequest: Equatable {
    public let normalizedWholeDisk: String
    public let volumeNames: [String]

    public init(wholeDisk: String, volumeNames: [String]) throws {
        let normalized = wholeDisk.hasPrefix("/dev/")
            ? String(wholeDisk.dropFirst("/dev/".count))
            : wholeDisk

        guard normalized.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) == nil else {
            throw AppError(message: "Use a whole disk such as /dev/disk13, not a partition such as /dev/disk13s2.")
        }
        guard normalized.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            throw AppError(message: "Expected a whole disk identifier such as /dev/disk13.")
        }
        guard volumeNames.count >= 2 else {
            throw AppError(message: "Partitioning needs at least two NTFS volume names.")
        }

        let cleanedNames = try volumeNames.map(Self.cleanVolumeName(_:))
        self.normalizedWholeDisk = normalized
        self.volumeNames = cleanedNames
    }

    public func diskutilArguments() -> [String] {
        var arguments = [
            "partitionDisk",
            "/dev/\(normalizedWholeDisk)",
            "GPT"
        ]

        for (index, name) in volumeNames.enumerated() {
            arguments += ["NTFS Access", name, index == volumeNames.count - 1 ? "R" : "\(100 / volumeNames.count)%"]
        }

        return arguments
    }

    private static func cleanVolumeName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AppError(message: "Volume names cannot be empty.")
        }
        guard name.count <= 32 else {
            throw AppError(message: "Volume name is too long: \(name)")
        }
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9 _.-]*$"#, options: .regularExpression) != nil else {
            throw AppError(message: "Volume names may contain only letters, numbers, spaces, dots, dashes, and underscores: \(name)")
        }
        return name
    }
}

public struct NTFSPartitionDiskSummary: Equatable {
    public let deviceIdentifier: String
    public let deviceNode: String
    public let mediaName: String?
    public let sizeBytes: UInt64?
    public let protocolName: String?
    public let isInternal: Bool
    public let isRemovable: Bool?
    public let isEjectable: Bool?
    public let isReadOnly: Bool
    public let partitionMap: String
    public let rawPlist: [String: Any]

    public var confirmationPhrase: String {
        "ERASE \(deviceIdentifier)"
    }

    public var humanReadableLines: [String] {
        var lines = [
            "Destructive NTFS partition dry-run:",
            "- Disk: \(deviceNode)",
            "- Media name: \(mediaName ?? "unknown")",
            "- Size: \(sizeBytes.map(Self.formatBytes(_:)) ?? "unknown")",
            "- Transport: \(protocolName ?? "unknown")",
            "- Internal: \(isInternal ? "yes" : "no")",
            "- Removable: \(isRemovable.map { $0 ? "yes" : "no" } ?? "unknown")",
            "- Ejectable: \(isEjectable.map { $0 ? "yes" : "no" } ?? "unknown")",
            "- Read-only: \(isReadOnly ? "yes" : "no")",
            "- Required confirmation: \(confirmationPhrase)"
        ]
        lines.append("- Current partition map:")
        if partitionMap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("  unavailable")
        } else {
            lines += partitionMap.split(separator: "\n").map { "  \(String($0))" }
        }
        return lines
    }

    public static func == (lhs: NTFSPartitionDiskSummary, rhs: NTFSPartitionDiskSummary) -> Bool {
        lhs.deviceIdentifier == rhs.deviceIdentifier
            && lhs.deviceNode == rhs.deviceNode
            && lhs.mediaName == rhs.mediaName
            && lhs.sizeBytes == rhs.sizeBytes
            && lhs.protocolName == rhs.protocolName
            && lhs.isInternal == rhs.isInternal
            && lhs.isRemovable == rhs.isRemovable
            && lhs.isEjectable == rhs.isEjectable
            && lhs.isReadOnly == rhs.isReadOnly
            && lhs.partitionMap == rhs.partitionMap
    }

    public func hasSameIdentity(as other: NTFSPartitionDiskSummary) -> Bool {
        deviceIdentifier == other.deviceIdentifier
            && deviceNode == other.deviceNode
            && mediaName == other.mediaName
            && sizeBytes == other.sizeBytes
            && isInternal == other.isInternal
            && isReadOnly == other.isReadOnly
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1 {
            return String(format: "%.2f GiB (%llu bytes)", gib, bytes)
        }
        let mib = Double(bytes) / 1_048_576
        return String(format: "%.2f MiB (%llu bytes)", mib, bytes)
    }
}

public final class NTFSPartitioner {
    public typealias CommandRunner = (String, [String], [String: String], TimeInterval) throws -> ShellResult

    private let commandRunner: CommandRunner

    public init(commandRunner: @escaping CommandRunner = Shell.run) {
        self.commandRunner = commandRunner
    }

    @discardableResult
    public func partition(request: NTFSPartitionRequest, confirmation: String) throws -> ShellResult {
        let summary = try inspectWholeExternalWritableDisk(request.normalizedWholeDisk)
        guard confirmation == summary.confirmationPhrase else {
            throw AppError(message: "Refusing to partition without typed confirmation: \(summary.confirmationPhrase)")
        }
        let finalSummary = try inspectWholeExternalWritableDisk(request.normalizedWholeDisk)
        guard summary.hasSameIdentity(as: finalSummary) else {
            throw AppError(message: "Refusing to partition because disk identity changed between confirmation and execution.")
        }
        return try commandRunner("/usr/sbin/diskutil", request.diskutilArguments(), [:], 600)
    }

    public func dryRunSummary(request: NTFSPartitionRequest) throws -> NTFSPartitionDiskSummary {
        try inspectWholeExternalWritableDisk(request.normalizedWholeDisk)
    }

    private func inspectWholeExternalWritableDisk(_ normalizedWholeDisk: String) throws -> NTFSPartitionDiskSummary {
        let result = try commandRunner("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(normalizedWholeDisk)"], [:], 15)
        guard result.status == 0 else {
            let detail = result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed
            throw AppError(message: "Unable to inspect /dev/\(normalizedWholeDisk): \(detail)")
        }

        guard let data = result.stdout.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw AppError(message: "Unable to parse diskutil info for /dev/\(normalizedWholeDisk)")
        }

        let deviceIdentifier = stringValue(plist, key: "DeviceIdentifier") ?? normalizedWholeDisk
        let deviceNode = stringValue(plist, key: "DeviceNode") ?? "/dev/\(deviceIdentifier)"
        let isInternal = boolValue(plist, key: "Internal") ?? boolValue(plist, key: "OSInternal") ?? true
        let isReadOnly = boolValue(plist, key: "MediaReadOnly")
            ?? boolValue(plist, key: "WritableMedia").map { !$0 }
            ?? false

        guard (boolValue(plist, key: "WholeDisk") ?? boolValue(plist, key: "Whole")) == true else {
            throw AppError(message: "/dev/\(normalizedWholeDisk) is not a whole disk.")
        }
        guard isInternal == false else {
            throw AppError(message: "Refusing to partition internal disk /dev/\(normalizedWholeDisk).")
        }
        guard isReadOnly == false else {
            throw AppError(message: "Refusing to partition read-only disk /dev/\(normalizedWholeDisk).")
        }

        let partitionMapResult = try commandRunner("/usr/sbin/diskutil", ["list", "/dev/\(normalizedWholeDisk)"], [:], 15)
        let partitionMap = partitionMapResult.status == 0
            ? partitionMapResult.stdout
            : (partitionMapResult.stderrTrimmed.isEmpty ? partitionMapResult.stdout : partitionMapResult.stderr)

        return NTFSPartitionDiskSummary(
            deviceIdentifier: deviceIdentifier,
            deviceNode: deviceNode,
            mediaName: stringValue(plist, key: "MediaName"),
            sizeBytes: numericValue(plist, keys: ["TotalSize", "Size", "IOKitSize"]),
            protocolName: stringValue(plist, key: "BusProtocol") ?? stringValue(plist, key: "Protocol"),
            isInternal: isInternal,
            isRemovable: boolValue(plist, key: "Removable"),
            isEjectable: boolValue(plist, key: "Ejectable"),
            isReadOnly: isReadOnly,
            partitionMap: partitionMap,
            rawPlist: plist
        )
    }

    private func boolValue(_ dictionary: [String: Any], key: String) -> Bool? {
        if let value = dictionary[key] as? Bool {
            return value
        }
        if let value = dictionary[key] as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    private func stringValue(_ dictionary: [String: Any], key: String) -> String? {
        let value = dictionary[key] as? String
        return value?.isEmpty == false ? value : nil
    }

    private func numericValue(_ dictionary: [String: Any], keys: [String]) -> UInt64? {
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                return number.uint64Value
            }
        }
        return nil
    }
}
