import Foundation

public struct MountConfiguration {
    public let mountRoot: String
    public let additionalOptions: [String]
    public let durabilityMode: MountDurabilityMode

    public init(
        mountRoot: String = "/Volumes",
        additionalOptions: [String] = [],
        durabilityMode: MountDurabilityMode = .performance
    ) {
        self.mountRoot = mountRoot
        self.additionalOptions = additionalOptions
        self.durabilityMode = durabilityMode
    }

    public func mountPoint(for volume: DiskVolume) -> String {
        let stableName = "NTFSAccess-\(sanitizeVolumeName(volume.stableIdentity))"
        return "\(mountRoot)/\(stableName)"
    }

    public func isManagedMountPoint(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else {
            return false
        }

        let normalizedRoot = mountRoot.hasSuffix("/") ? String(mountRoot.dropLast()) : mountRoot
        return path.hasPrefix("\(normalizedRoot)/NTFSAccess-")
    }

    public func readWriteOptionSets(for volume: DiskVolume, user: ConsoleUser) -> [[String]] {
        let finderCompatible = withAdditionalOptions(["allow_other", "defer_permissions"])
        let named = withAdditionalOptions(finderCompatible + ["volname=\(sanitizeOptionValue(volume.volumeName))"])
        let localNamed = withAdditionalOptions(named + ["local"])
        let extended = withAdditionalOptions(localNamed + extendedWritableOptions())

        return uniqueOptionSets([extended, localNamed, named, finderCompatible])
    }

    public func readOnlyOptionSets(for volume: DiskVolume, user: ConsoleUser) -> [[String]] {
        let base = baseOwnershipOptions(for: user)
        let finderCompatible = withAdditionalOptions(base + ["allow_other", "ro"])
        let named = withAdditionalOptions(finderCompatible + ["volname=\(sanitizeOptionValue(volume.volumeName))"])
        let localNamed = withAdditionalOptions(named + ["local"])
        let extended = withAdditionalOptions(localNamed + ["noatime"])
        let minimal = withAdditionalOptions(base + ["ro"])

        return uniqueOptionSets([localNamed, extended, named, finderCompatible, minimal])
    }

    public func readWriteOptions(for volume: DiskVolume, user: ConsoleUser) -> [String] {
        readWriteOptionSets(for: volume, user: user).first ?? []
    }

    public func withDurabilityMode(_ mode: MountDurabilityMode) -> MountConfiguration {
        MountConfiguration(
            mountRoot: mountRoot,
            additionalOptions: additionalOptions,
            durabilityMode: mode
        )
    }

    private func baseOwnershipOptions(for user: ConsoleUser) -> [String] {
        [
            "uid=\(user.uid)",
            "gid=\(user.gid)",
            "umask=022"
        ]
    }

    private func withAdditionalOptions(_ options: [String]) -> [String] {
        options + additionalOptions
    }

    private func extendedWritableOptions() -> [String] {
        var options = [
            "auto_xattr",
            "auto_cache",
            "big_writes",
            "noatime"
        ]
        if durabilityMode == .performance {
            options.append(contentsOf: ["nosyncwrites", "nosynconclose"])
        }
        options.append(contentsOf: ["iosize=1048576", "daemon_timeout=60"])
        return options
    }

    public func sanitizeVolumeName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. ")
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }

        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "NTFS-Volume" : cleaned
    }

    private func sanitizeOptionValue(_ raw: String) -> String {
        sanitizeVolumeName(raw).replacingOccurrences(of: " ", with: "_")
    }

    private func uniqueOptionSets(_ sets: [[String]]) -> [[String]] {
        var seen = Set<String>()
        return sets.filter { options in
            let key = options.joined(separator: ",")
            return seen.insert(key).inserted
        }
    }
}
