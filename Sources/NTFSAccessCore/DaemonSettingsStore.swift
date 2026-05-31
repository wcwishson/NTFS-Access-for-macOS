import Foundation

public final class DaemonSettingsStore {
    private struct PersistedSettings: Codable {
        var notificationsEnabled: Bool?
        var durabilityMode: MountDurabilityMode?
    }

    private let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = URL(fileURLWithPath: NTFSAccessPaths.daemonSettingsPath),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() -> DaemonSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return DaemonSettings()
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let persisted = try PropertyListDecoder().decode(PersistedSettings.self, from: data)
            return DaemonSettings(
                notificationsEnabled: persisted.notificationsEnabled ?? true,
                durabilityMode: persisted.durabilityMode ?? .performance
            )
        } catch {
            Log.warning("Unable to load daemon settings from \(fileURL.path): \(error.localizedDescription)")
            return DaemonSettings()
        }
    }

    public func save(_ settings: DaemonSettings) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let data = try PropertyListEncoder().encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
