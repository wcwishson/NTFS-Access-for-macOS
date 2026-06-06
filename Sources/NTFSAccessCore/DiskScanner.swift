import Foundation

public protocol DiskScanning {
    func listNTFSVolumes(externalOnly: Bool) throws -> [DiskVolume]
    func info(for deviceIdentifier: String) throws -> DiskVolume
    func deviceNoLongerPresent(_ error: Error) -> Bool
}

public extension DiskScanning {
    func deviceNoLongerPresent(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("could not find disk")
            || message.contains("no such disk")
            || message.contains("no such device")
            || message.contains("does not exist")
    }
}

public final class DiskScanner: DiskScanning {
    private let diskutilPlistRunner: ([String], String, TimeInterval) throws -> [String: Any]

    public convenience init() {
        self.init(diskutilPlistRunner: Self.defaultDiskutilPlist)
    }

    init(diskutilPlistRunner: @escaping ([String], String, TimeInterval) throws -> [String: Any]) {
        self.diskutilPlistRunner = diskutilPlistRunner
    }

    public func listNTFSVolumes(externalOnly: Bool) throws -> [DiskVolume] {
        let listPlist: [String: Any]
        do {
            listPlist = try diskutilListPlist()
        } catch {
            Log.warning("Global diskutil list failed; falling back to direct /dev partition scan: \(error.localizedDescription)")
            return try fallbackVolumesOnListFailure(externalOnly: externalOnly, originalError: error)
        }

        var namesByWholeDisk: [String: String] = [:]
        var queriedWholeDisks = Set<String>()
        func cachedWholeDiskName(_ wholeDisk: String?) -> String? {
            guard let wholeDisk, !wholeDisk.isEmpty else {
                return nil
            }
            guard !queriedWholeDisks.contains(wholeDisk) else {
                return namesByWholeDisk[wholeDisk]
            }
            queriedWholeDisks.insert(wholeDisk)
            guard let name = try? info(for: wholeDisk).parentWholeDiskName,
                  !name.isEmpty else {
                return nil
            }
            namesByWholeDisk[wholeDisk] = name
            return name
        }

        let fallbackVolumes = parseDiskListVolumes(listPlist).enrichingWholeDiskNames { wholeDisk in
            cachedWholeDiskName(wholeDisk)
        }
        let fallbackByIdentifier = Dictionary(uniqueKeysWithValues: fallbackVolumes.map { ($0.deviceIdentifier, $0) })
        let identifiers = allPartitionIdentifiers(from: listPlist).filter { identifier in
            guard externalOnly, let fallbackVolume = fallbackByIdentifier[identifier] else {
                return true
            }
            return fallbackVolume.isExternal
        }
        var volumes: [DiskVolume] = []
        var seen = Set<String>()

        for fallbackVolume in fallbackVolumes {
            if externalOnly && !fallbackVolume.isExternal {
                continue
            }
            let baseVolume = (try? info(for: fallbackVolume.deviceIdentifier)) ?? fallbackVolume
            let volume = baseVolume
                .mergingPhysicalDriveMetadata(from: fallbackVolume)
                .mergingPhysicalDriveMetadata(
                    parentWholeDisk: baseVolume.parentWholeDisk ?? fallbackVolume.parentWholeDisk,
                    parentWholeDiskName: cachedWholeDiskName(baseVolume.parentWholeDisk ?? fallbackVolume.parentWholeDisk)
                )
            guard volume.isNTFS else {
                continue
            }
            if externalOnly && !volume.isExternal {
                continue
            }
            volumes.append(volume)
            seen.insert(volume.deviceIdentifier)
        }

        for identifier in identifiers where !seen.contains(identifier) {
            guard let baseVolume = try? info(for: identifier), baseVolume.isNTFS else {
                continue
            }
            let volume = baseVolume.mergingPhysicalDriveMetadata(
                parentWholeDisk: baseVolume.parentWholeDisk,
                parentWholeDiskName: cachedWholeDiskName(baseVolume.parentWholeDisk)
            )
            if externalOnly && !volume.isExternal {
                continue
            }
            volumes.append(volume)
        }

        return volumes.sorted { $0.deviceIdentifier < $1.deviceIdentifier }
    }

    private func fallbackVolumesOnListFailure(externalOnly: Bool, originalError: Error) throws -> [DiskVolume] {
        do {
            let fallbackVolumes = try listNTFSVolumesFromDeviceNodes(externalOnly: externalOnly)
            if !fallbackVolumes.isEmpty {
                Log.warning("Returning \(fallbackVolumes.count) NTFS volume(s) from direct /dev partition scan after global diskutil list failure")
                return fallbackVolumes
            }
        } catch let fallbackError {
            Log.warning("Direct /dev partition scan also failed: \(fallbackError.localizedDescription)")
        }

        throw originalError
    }

    func listNTFSVolumesFromDeviceNodes(externalOnly: Bool) throws -> [DiskVolume] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: "/dev")
        let identifiers = partitionIdentifiers(fromDevDirectoryEntries: entries)
        var volumes: [DiskVolume] = []
        var seen = Set<String>()
        var sawDiskutilTimeout = false

        for identifier in identifiers where !seen.contains(identifier) {
            if sawDiskutilTimeout && isLikelyInternalDeviceIdentifier(identifier) {
                continue
            }

            let volume: DiskVolume
            do {
                volume = try info(for: identifier)
            } catch {
                if Self.isDiskutilTimeout(error) {
                    sawDiskutilTimeout = true
                    Log.warning("Stopping direct /dev scan after diskutil info timed out for \(identifier); skipping likely internal partitions to avoid blocking NTFS recovery")
                    if isLikelyInternalDeviceIdentifier(identifier) {
                        continue
                    }
                }
                continue
            }

            guard volume.isNTFS else {
                continue
            }
            if externalOnly && !volume.isExternal {
                continue
            }
            volumes.append(volume)
            seen.insert(volume.deviceIdentifier)
        }

        return volumes.sorted { $0.deviceIdentifier < $1.deviceIdentifier }
    }

    func partitionIdentifiers(fromDevDirectoryEntries entries: [String]) -> [String] {
        partitionIdentifiers(fromDiskListIdentifiers: entries)
    }

    func partitionIdentifiers(fromDiskListIdentifiers identifiers: some Sequence<String>) -> [String] {
        identifiers
            .filter(isPartitionIdentifier)
            .sorted()
    }

    func isPartitionIdentifier(_ identifier: String) -> Bool {
        identifier.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil
    }

    func isLikelyInternalDeviceIdentifier(_ identifier: String) -> Bool {
        guard let number = diskNumber(fromPartitionIdentifier: identifier) else {
            return false
        }
        return number <= 3
    }

    public func info(for deviceIdentifier: String) throws -> DiskVolume {
        let normalized = normalizeDeviceIdentifier(deviceIdentifier)
        let plist = try diskutilPlist(
            arguments: ["info", "-plist", "/dev/\(normalized)"],
            description: "diskutil info for \(normalized)",
            timeout: 12
        )
        if let errorMessage = stringValue(plist, key: "ErrorMessage") {
            throw AppError(message: errorMessage)
        }
        guard !plist.isEmpty else {
            throw AppError(message: "Unable to parse diskutil info for \(normalized)")
        }
        return parseDiskVolume(plist, fallbackIdentifier: normalized)
    }

    public func normalizeDeviceIdentifier(_ raw: String) -> String {
        if raw.hasPrefix("/dev/") {
            return String(raw.dropFirst("/dev/".count))
        }
        return raw
    }

    public func parseDiskVolume(_ plist: [String: Any], fallbackIdentifier: String) -> DiskVolume {
        let identifier = stringValue(plist, key: "DeviceIdentifier") ?? fallbackIdentifier
        let node = stringValue(plist, key: "DeviceNode") ?? "/dev/\(identifier)"
        let mountPoint = stringValue(plist, key: "MountPoint")
        let volumeUUID = firstNonEmpty([
            stringValue(plist, key: "VolumeUUID"),
            stringValue(plist, key: "APFSVolumeUUID")
        ])
        let diskUUID = stringValue(plist, key: "DiskUUID")
        let mediaUUID = firstNonEmpty([
            stringValue(plist, key: "MediaUUID"),
            stringValue(plist, key: "UUID")
        ])
        let volumeName = firstNonEmpty([
            stringValue(plist, key: "VolumeName"),
            stringValue(plist, key: "MediaName"),
            identifier
        ]) ?? identifier
        let mediaName = firstNonEmpty([
            stringValue(plist, key: "MediaName"),
            volumeName
        ]) ?? volumeName

        let hasUsableMountPoint = mountPoint != nil
        let rawMounted = boolValue(plist, key: "Mounted") ?? hasUsableMountPoint
        let isMounted = rawMounted && hasUsableMountPoint
        let isWritable = isMounted && (boolValue(plist, key: "Writable") ?? boolValue(plist, key: "WritableVolume") ?? false)

        return DiskVolume(
            deviceIdentifier: identifier,
            deviceNode: node,
            volumeUUID: volumeUUID,
            diskUUID: diskUUID,
            mediaUUID: mediaUUID,
            parentWholeDisk: stringValue(plist, key: "ParentWholeDisk"),
            parentWholeDiskName: parentWholeDiskName(from: plist),
            partitionMapPartitionOffset: int64Value(plist, key: "PartitionMapPartitionOffset"),
            size: firstNonNil([
                int64Value(plist, key: "VolumeSize"),
                int64Value(plist, key: "TotalSize"),
                int64Value(plist, key: "Size"),
                int64Value(plist, key: "IOKitSize")
            ]),
            volumeName: volumeName,
            mediaName: mediaName,
            filesystemType: stringValue(plist, key: "FilesystemType"),
            filesystemName: stringValue(plist, key: "FilesystemName"),
            mountPoint: mountPoint,
            isMounted: isMounted,
            isWritable: isWritable,
            isInternal: boolValue(plist, key: "Internal") ?? boolValue(plist, key: "OSInternal") ?? false
        )
    }

    public func parseDiskListVolumes(_ plist: [String: Any]) -> [DiskVolume] {
        guard let nodes = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        var volumes: [DiskVolume] = []
        for node in nodes {
            collectDiskListVolumes(
                node,
                inheritedInternal: false,
                parentWholeDisk: stringValue(node, key: "DeviceIdentifier"),
                parentWholeDiskName: physicalDriveName(from: node),
                into: &volumes
            )
        }
        return volumes
    }

    private func diskutilListPlist() throws -> [String: Any] {
        try diskutilPlist(arguments: ["list", "-plist"], description: "diskutil list", timeout: 20)
    }

    func allPartitionIdentifiers(from plist: [String: Any]) -> [String] {
        if let nodes = plist["AllDisksAndPartitions"] as? [[String: Any]] {
            var globalIdentifiers: [String] = []
            for node in nodes {
                collectIdentifiers(node, into: &globalIdentifiers)
            }

            let globalPartitions = partitionIdentifiers(fromDiskListIdentifiers: globalIdentifiers)
            if !globalPartitions.isEmpty {
                return globalPartitions
            }
        }

        var identifiers = Set<String>()
        var wholeDiskLookupFailed = false

        if let wholeDisks = plist["WholeDisks"] as? [String], !wholeDisks.isEmpty {
            for wholeDisk in wholeDisks {
                do {
                    for identifier in try partitionIdentifiers(forWholeDisk: wholeDisk) {
                        identifiers.insert(identifier)
                    }
                } catch {
                    wholeDiskLookupFailed = true
                    Log.warning("Unable to enumerate partitions for \(wholeDisk); falling back to global disk list entries for that disk: \(error.localizedDescription)")
                }
            }
        }

        if wholeDiskLookupFailed, let nodes = plist["AllDisksAndPartitions"] as? [[String: Any]] {
            var output: [String] = []
            for node in nodes {
                collectIdentifiers(node, into: &output)
            }
            identifiers.formUnion(output)
        }

        if identifiers.isEmpty, let nodes = plist["AllDisksAndPartitions"] as? [[String: Any]] {
            var output: [String] = []
            for node in nodes {
                collectIdentifiers(node, into: &output)
            }
            identifiers.formUnion(output)
        }

        return partitionIdentifiers(fromDiskListIdentifiers: identifiers)
    }

    private func partitionIdentifiers(forWholeDisk wholeDisk: String) throws -> [String] {
        let normalized = normalizeDeviceIdentifier(wholeDisk)
        let result = try Shell.runChecked("/usr/sbin/diskutil", ["list", "-plist", "/dev/\(normalized)"], timeout: 20)
        guard let plist = try parsePlistDictionary(from: result.stdout) else {
            throw AppError(message: "Unable to parse diskutil list output for \(normalized)")
        }

        if let allDisks = plist["AllDisks"] as? [String], !allDisks.isEmpty {
            return allDisks
        }

        var output: [String] = []
        if let nodes = plist["AllDisksAndPartitions"] as? [[String: Any]] {
            for node in nodes {
                collectIdentifiers(node, into: &output)
            }
        }
        return output
    }

    private func collectDiskListVolumes(
        _ node: [String: Any],
        inheritedInternal: Bool,
        parentWholeDisk: String?,
        parentWholeDiskName: String?,
        into volumes: inout [DiskVolume]
    ) {
        let isInternal = boolValue(node, key: "OSInternal")
            ?? boolValue(node, key: "Internal")
            ?? inheritedInternal

        if let partitions = node["Partitions"] as? [[String: Any]] {
            let wholeDisk = stringValue(node, key: "DeviceIdentifier") ?? parentWholeDisk
            let wholeDiskName = physicalDriveName(from: node) ?? parentWholeDiskName ?? wholeDisk
            for partition in partitions {
                collectDiskListVolumes(
                    partition,
                    inheritedInternal: isInternal,
                    parentWholeDisk: wholeDisk,
                    parentWholeDiskName: wholeDiskName,
                    into: &volumes
                )
            }
            return
        }

        guard let identifier = stringValue(node, key: "DeviceIdentifier") else {
            return
        }

        let content = stringValue(node, key: "Content")
        let volumeName = firstNonEmpty([
            stringValue(node, key: "VolumeName"),
            stringValue(node, key: "MediaName"),
            identifier
        ]) ?? identifier
        let mountPoint = stringValue(node, key: "MountPoint")
        let filesystemType = diskListFilesystemType(from: content)
        let filesystemName = filesystemNameForDiskListContent(content)
        let size = int64Value(node, key: "Size")

        let volume = DiskVolume(
            deviceIdentifier: identifier,
            deviceNode: "/dev/\(identifier)",
            diskUUID: stringValue(node, key: "DiskUUID"),
            parentWholeDisk: parentWholeDisk,
            parentWholeDiskName: parentWholeDiskName,
            size: size,
            volumeName: volumeName,
            mediaName: firstNonEmpty([stringValue(node, key: "MediaName"), volumeName]) ?? volumeName,
            filesystemType: filesystemType,
            filesystemName: filesystemName,
            mountPoint: mountPoint,
            isMounted: mountPoint != nil,
            isWritable: false,
            isInternal: isInternal
        )

        if volume.isNTFS {
            volumes.append(volume)
        }
    }

    private func parentWholeDiskName(from plist: [String: Any]) -> String? {
        let isPartition = boolValue(plist, key: "PartitionMapPartition") ?? false
        let isWholeDisk = boolValue(plist, key: "WholeDisk") ?? false
        if isPartition || (!isWholeDisk && stringValue(plist, key: "ParentWholeDisk") != nil) {
            return stringValue(plist, key: "ParentWholeDiskName")
        }

        return firstNonEmpty([
            stringValue(plist, key: "ParentWholeDiskName"),
            physicalDriveName(from: plist)
        ])
    }

    private func physicalDriveName(from node: [String: Any]) -> String? {
        firstNonEmpty([
            stringValue(node, key: "MediaName"),
            stringValue(node, key: "IORegistryEntryName")
        ])
    }

    private func diskListFilesystemType(from content: String?) -> String? {
        guard let content else {
            return nil
        }
        if content.localizedCaseInsensitiveContains("Windows_NTFS") {
            return "ntfs"
        }
        if content.localizedCaseInsensitiveContains("ntfsaccess") {
            return "ntfsaccess"
        }
        return content.lowercased()
    }

    private func filesystemNameForDiskListContent(_ content: String?) -> String? {
        guard let content else {
            return nil
        }
        if content.localizedCaseInsensitiveContains("Windows_NTFS") {
            return "Windows NT Filesystem"
        }
        if content.localizedCaseInsensitiveContains("ntfsaccess") {
            return "NTFS Access"
        }
        return content
    }

    private func collectIdentifiers(_ node: [String: Any], into output: inout [String]) {
        if let identifier = node["DeviceIdentifier"] as? String {
            output.append(identifier)
        }

        if let partitions = node["Partitions"] as? [[String: Any]] {
            for part in partitions {
                collectIdentifiers(part, into: &output)
            }
        }
    }

    private func diskutilPlist(arguments: [String], description: String, timeout: TimeInterval) throws -> [String: Any] {
        try diskutilPlistRunner(arguments, description, timeout)
    }

    private static func defaultDiskutilPlist(arguments: [String], description: String, timeout: TimeInterval) throws -> [String: Any] {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let result = try Shell.runChecked("/usr/sbin/diskutil", arguments, timeout: timeout)
                guard let plist = try parsePlistDictionaryBody(from: result.stdout) else {
                    throw AppError(message: "Unable to parse \(description)")
                }
                return plist
            } catch {
                lastError = error
                if Self.isDiskutilTimeout(error) {
                    break
                }
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.2 * Double(attempt))
                }
            }
        }
        throw lastError ?? AppError(message: "Unable to parse \(description)")
    }

    func parsePlistDictionary(from string: String) throws -> [String: Any]? {
        try Self.parsePlistDictionaryBody(from: string)
    }

    private static func parsePlistDictionaryBody(from string: String) throws -> [String: Any]? {
        let body = plistBody(from: string)
        guard let data = body.data(using: .utf8) else {
            return nil
        }
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return object as? [String: Any]
    }

    private static func plistBody(from string: String) -> String {
        guard let start = string.range(of: "<?xml") ?? string.range(of: "<plist"),
              let end = string.range(of: "</plist>", options: .backwards) else {
            return string
        }

        return String(string[start.lowerBound..<end.upperBound])
    }

    private static func isDiskutilTimeout(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("timed out")
            || message.contains("timeout")
            || message.contains("not responding")
    }

    private func diskNumber(fromPartitionIdentifier identifier: String) -> Int? {
        guard identifier.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        let body = identifier.dropFirst("disk".count)
        return body.split(separator: "s", maxSplits: 1).first.flatMap { Int(String($0)) }
    }

    private func stringValue(_ dictionary: [String: Any], key: String) -> String? {
        guard let raw = dictionary[key] as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func boolValue(_ dictionary: [String: Any], key: String) -> Bool? {
        if let value = dictionary[key] as? Bool {
            return value
        }
        if let number = dictionary[key] as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private func int64Value(_ dictionary: [String: Any], key: String) -> Int64? {
        if let value = dictionary[key] as? Int64 {
            return value
        }
        if let value = dictionary[key] as? Int {
            return Int64(value)
        }
        if let value = dictionary[key] as? NSNumber {
            return value.int64Value
        }
        if let raw = dictionary[key] as? String,
           let value = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        return nil
    }

    private func firstNonNil<T>(_ values: [T?]) -> T? {
        for value in values {
            if let value {
                return value
            }
        }
        return nil
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

private extension Array where Element == DiskVolume {
    func enrichingWholeDiskNames(_ nameForWholeDisk: (String) -> String?) -> [DiskVolume] {
        var namesByWholeDisk: [String: String] = [:]
        var queriedWholeDisks = Set<String>()

        return map { volume in
            guard let wholeDisk = volume.parentWholeDisk,
                  !wholeDisk.isEmpty,
                  volume.parentWholeDiskName == wholeDisk else {
                return volume
            }

            if !queriedWholeDisks.contains(wholeDisk) {
                queriedWholeDisks.insert(wholeDisk)
                if let name = nameForWholeDisk(wholeDisk), !name.isEmpty {
                    namesByWholeDisk[wholeDisk] = name
                }
            }

            guard let name = namesByWholeDisk[wholeDisk], !name.isEmpty else {
                return volume
            }

            return volume.mergingPhysicalDriveMetadata(
                parentWholeDisk: wholeDisk,
                parentWholeDiskName: name
            )
        }
    }
}
