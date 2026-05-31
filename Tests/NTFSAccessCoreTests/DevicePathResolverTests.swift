@testable import NTFSAccessCore
import XCTest

final class DevicePathResolverTests: XCTestCase {
    func testRejectsNonDiskDevice() {
        XCTAssertThrowsError(try DevicePathResolver.normalizedBlockDevicePath("/dev/null"))
    }

    func testNormalizesDiskIdentifierWhenPresent() throws {
        guard FileManager.default.fileExists(atPath: "/dev/disk0") else {
            throw XCTSkip("disk0 not present on this host")
        }

        let path = try DevicePathResolver.normalizedBlockDevicePath("disk0")
        XCTAssertEqual(path, "/dev/disk0")
    }

    func testFormatSafetyRejectsWholeDiskByDefault() {
        let geometry = DiskDeviceGeometry(
            blockDevicePath: "/dev/disk13",
            sectorSize: 512,
            totalSectors: 1000,
            partitionStartSector: nil,
            isWholeDisk: true,
            isInternal: false,
            mediaReadOnly: false
        )

        XCTAssertThrowsError(try DevicePathResolver.validateSafeFormatTarget(geometry)) { error in
            XCTAssertTrue(error.localizedDescription.contains("partition"))
        }
    }

    func testFormatSafetyRejectsInternalPartitionByDefault() {
        let geometry = DiskDeviceGeometry(
            blockDevicePath: "/dev/disk0s2",
            sectorSize: 512,
            totalSectors: 1000,
            partitionStartSector: 40,
            isWholeDisk: false,
            isInternal: true,
            mediaReadOnly: false
        )

        XCTAssertThrowsError(try DevicePathResolver.validateSafeFormatTarget(geometry)) { error in
            XCTAssertTrue(error.localizedDescription.contains("internal"))
        }
    }

    func testFormatSafetyRequiresPartitionShapedTargetByDefault() {
        let geometry = DiskDeviceGeometry(
            blockDevicePath: "/dev/disk13",
            sectorSize: 512,
            totalSectors: 1000,
            partitionStartSector: 40,
            isWholeDisk: false,
            isInternal: false,
            mediaReadOnly: false
        )

        XCTAssertThrowsError(try DevicePathResolver.validateSafeFormatTarget(geometry)) { error in
            XCTAssertTrue(error.localizedDescription.contains("/dev/disk13s2"))
        }
    }

    func testFormatSafetyAllowsExternalWritablePartition() throws {
        let geometry = DiskDeviceGeometry(
            blockDevicePath: "/dev/disk13s2",
            sectorSize: 512,
            totalSectors: 1000,
            partitionStartSector: 40,
            isWholeDisk: false,
            isInternal: false,
            mediaReadOnly: false
        )

        XCTAssertNoThrow(try DevicePathResolver.validateSafeFormatTarget(geometry))
    }

    func testFormatSafetyAllowsDeveloperOverride() throws {
        let geometry = DiskDeviceGeometry(
            blockDevicePath: "/dev/disk13",
            sectorSize: 512,
            totalSectors: 1000,
            partitionStartSector: nil,
            isWholeDisk: true,
            isInternal: true,
            mediaReadOnly: false
        )

        XCTAssertNoThrow(try DevicePathResolver.validateSafeFormatTarget(geometry, allowUnsafeTarget: true))
    }
}
