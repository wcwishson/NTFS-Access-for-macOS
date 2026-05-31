import Foundation

public enum FileSystemPersonalityInspector {
    public static func listFormattableFileSystems() throws -> String {
        try Shell.runChecked("/usr/sbin/diskutil", ["listFilesystems"], timeout: 20).stdout
    }

    public static func formatterPersonalityRegistered(name: String = NTFSAccessPaths.formatterPersonalityName) -> Bool {
        guard let output = try? listFormattableFileSystems() else {
            return false
        }

        return output
            .localizedCaseInsensitiveContains(name)
            || output.localizedCaseInsensitiveContains(NTFSAccessPaths.formatterUserVisibleName)
    }

    public static func detectedNTFSPersonalities() -> [String] {
        guard let output = try? listFormattableFileSystems() else {
            return []
        }

        let ignoredPrefixes = ["PERSONALITY", "These ", "When ", "Certain ", "Formattable "]
        var names: [String] = []

        for line in output.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                continue
            }
            if ignoredPrefixes.contains(where: { text.hasPrefix($0) }) || text.hasPrefix("-") || text.hasPrefix("(or)") {
                continue
            }
            if !text.localizedCaseInsensitiveContains("NTFS") {
                continue
            }

            let columns = text.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            if columns.isEmpty {
                continue
            }

            if let first = text.components(separatedBy: "  ").first?.trimmingCharacters(in: .whitespaces), !first.isEmpty {
                names.append(first)
            } else {
                names.append(text)
            }
        }

        return Array(Set(names)).sorted()
    }

    public static func formatterProbeOrders(infoPlistPath: String = NTFSAccessPaths.formatterInfoPlistPath) -> [String: Int] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: infoPlistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let mediaTypes = plist["FSMediaTypes"] as? [String: Any] else {
            return [:]
        }

        var probeOrders: [String: Int] = [:]
        for (mediaType, rawEntry) in mediaTypes {
            guard let entry = rawEntry as? [String: Any] else {
                continue
            }
            if let order = entry["FSProbeOrder"] as? Int {
                probeOrders[mediaType] = order
            } else if let order = entry["FSProbeOrder"] as? NSNumber {
                probeOrders[mediaType] = order.intValue
            }
        }
        return probeOrders
    }
}
