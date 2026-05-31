@testable import NTFSAccessCore
import XCTest

final class DaemonSettingsStoreTests: XCTestCase {
    func testMissingSettingsDefaultToNotificationsOnAndPerformanceDurability() {
        let store = DaemonSettingsStore(fileURL: temporarySettingsURL())

        let settings = store.load()

        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertEqual(settings.durabilityMode, .performance)
    }

    func testDurabilityModeRoundTripsThroughSettingsStore() throws {
        let url = temporarySettingsURL()
        let store = DaemonSettingsStore(fileURL: url)

        try store.save(DaemonSettings(notificationsEnabled: false, durabilityMode: .conservative))
        let settings = store.load()

        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertEqual(settings.durabilityMode, .conservative)
    }

    func testLegacySettingsWithoutDurabilityModeDefaultToPerformance() throws {
        let url = temporarySettingsURL()
        let legacySettings = ["notificationsEnabled": false]
        let data = try PropertyListSerialization.data(fromPropertyList: legacySettings, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let settings = DaemonSettingsStore(fileURL: url).load()

        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertEqual(settings.durabilityMode, .performance)
    }

    private func temporarySettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsaccess-settings-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("daemon-settings.plist")
    }
}
