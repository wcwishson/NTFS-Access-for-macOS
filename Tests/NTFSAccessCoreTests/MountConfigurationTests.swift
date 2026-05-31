@testable import NTFSAccessCore
import XCTest

final class MountConfigurationTests: XCTestCase {
    func testSanitizeVolumeName() {
        let config = MountConfiguration()
        XCTAssertEqual(config.sanitizeVolumeName("My:Drive*2026"), "My_Drive_2026")
    }

    func testMountPointUsesStableIdentityWhenDiskUUIDExists() {
        let config = MountConfiguration()
        let volume = DiskVolume(
            deviceIdentifier: "disk14s2",
            deviceNode: "/dev/disk14s2",
            diskUUID: "2D253235-C29F-4EDA-B308-13F6DB9DA6DD",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        XCTAssertEqual(
            config.mountPoint(for: volume),
            "/Volumes/NTFSAccess-diskuuid-2D253235-C29F-4EDA-B308-13F6DB9DA6DD"
        )
    }

    func testReadWriteOptionSetsPreferMacStableOptionsWithVolumeName() {
        let config = MountConfiguration()
        let volume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        let optionSets = config.readWriteOptionSets(for: volume, user: ConsoleUser(uid: 501, gid: 20))
        let firstOptions = optionSets[0].joined(separator: ",")
        XCTAssertFalse(firstOptions.contains("uid=501"))
        XCTAssertFalse(firstOptions.contains("gid=20"))
        XCTAssertFalse(firstOptions.contains("umask=022"))
        XCTAssertTrue(firstOptions.contains("allow_other"))
        XCTAssertTrue(firstOptions.contains("volname=Passport"))
        XCTAssertTrue(firstOptions.contains("local"))
        XCTAssertTrue(firstOptions.contains("defer_permissions"))
        XCTAssertFalse(firstOptions.contains("default_permissions"))
        XCTAssertTrue(firstOptions.contains("auto_xattr"))
        XCTAssertFalse(firstOptions.contains("noapplexattr"))
        XCTAssertFalse(firstOptions.contains("noappledouble"))
        XCTAssertTrue(firstOptions.contains("auto_cache"))
        XCTAssertTrue(firstOptions.contains("big_writes"))
        XCTAssertTrue(firstOptions.contains("nosyncwrites"))
        XCTAssertTrue(firstOptions.contains("nosynconclose"))
        XCTAssertTrue(firstOptions.contains("iosize=1048576"))
        XCTAssertTrue(firstOptions.contains("daemon_timeout=60"))
    }

    func testReadWriteOptionSetsAllowFinderMetadataWrites() {
        let config = MountConfiguration()
        let volume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        let flattened = config.readWriteOptionSets(for: volume, user: ConsoleUser(uid: 501, gid: 20))
            .flatMap { $0 }

        XCTAssertTrue(flattened.contains("auto_xattr"))
        XCTAssertTrue(flattened.contains("nosyncwrites"))
        XCTAssertTrue(flattened.contains("nosynconclose"))
        XCTAssertFalse(flattened.contains("noapplexattr"))
        XCTAssertFalse(flattened.contains("noappledouble"))
    }

    func testReadWriteOptionSetsDeferMacFUSEPermissionChecksForFinderAccess() {
        let config = MountConfiguration()
        let volume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        let optionSets = config.readWriteOptionSets(for: volume, user: ConsoleUser(uid: 501, gid: 20))

        XCTAssertFalse(optionSets.isEmpty)
        for options in optionSets {
            XCTAssertTrue(options.contains("allow_other"), options.joined(separator: ","))
            XCTAssertTrue(options.contains("defer_permissions"), options.joined(separator: ","))
            XCTAssertFalse(options.contains("default_permissions"), options.joined(separator: ","))
            XCTAssertFalse(options.contains("uid=501"), options.joined(separator: ","))
            XCTAssertFalse(options.contains("gid=20"), options.joined(separator: ","))
            XCTAssertFalse(options.contains("umask=022"), options.joined(separator: ","))
        }
    }

    func testReadWriteOptionSetsAvoidNTFS3GDefaultPermissionsTriggersWhenDeferringMacFUSEPermissions() {
        let config = MountConfiguration()
        let volume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        let optionSets = config.readWriteOptionSets(for: volume, user: ConsoleUser(uid: 501, gid: 20))

        for options in optionSets {
            XCTAssertTrue(options.contains("defer_permissions"), options.joined(separator: ","))
            XCTAssertFalse(options.contains { $0.hasPrefix("uid=") }, options.joined(separator: ","))
            XCTAssertFalse(options.contains { $0.hasPrefix("gid=") }, options.joined(separator: ","))
            XCTAssertFalse(options.contains { $0.hasPrefix("umask=") }, options.joined(separator: ","))
            XCTAssertFalse(options.contains { $0.hasPrefix("fmask=") }, options.joined(separator: ","))
            XCTAssertFalse(options.contains { $0.hasPrefix("dmask=") }, options.joined(separator: ","))
            XCTAssertFalse(options.contains("permissions"), options.joined(separator: ","))
            XCTAssertFalse(options.contains("acl"), options.joined(separator: ","))
        }
    }

    func testReadWriteOptionSetsRetainUnnamedFallback() {
        let config = MountConfiguration()
        let volume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        let optionSets = config.readWriteOptionSets(for: volume, user: ConsoleUser(uid: 501, gid: 20))
        XCTAssertTrue(optionSets.map { $0.joined(separator: ",") }.contains("allow_other,defer_permissions"))
        XCTAssertTrue(optionSets.map { $0.joined(separator: ",") }.contains("allow_other,defer_permissions,volname=Passport"))
    }

    func testConservativeDurabilityModeRemovesOnlyNoSyncWriteOptionsFromPreferredWritableMount() {
        let config = MountConfiguration(durabilityMode: .conservative)
        let volume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        let firstOptions = config.readWriteOptionSets(for: volume, user: ConsoleUser(uid: 501, gid: 20))[0]

        XCTAssertTrue(firstOptions.contains("allow_other"))
        XCTAssertTrue(firstOptions.contains("defer_permissions"))
        XCTAssertTrue(firstOptions.contains("volname=Passport"))
        XCTAssertTrue(firstOptions.contains("local"))
        XCTAssertTrue(firstOptions.contains("auto_xattr"))
        XCTAssertTrue(firstOptions.contains("auto_cache"))
        XCTAssertTrue(firstOptions.contains("big_writes"))
        XCTAssertTrue(firstOptions.contains("noatime"))
        XCTAssertTrue(firstOptions.contains("iosize=1048576"))
        XCTAssertTrue(firstOptions.contains("daemon_timeout=60"))
        XCTAssertFalse(firstOptions.contains("nosyncwrites"))
        XCTAssertFalse(firstOptions.contains("nosynconclose"))
    }

    func testReadOnlyOptionSetsUseVolumeNameFirstForFinderDisplay() {
        let config = MountConfiguration()
        let volume = DiskVolume(
            deviceIdentifier: "disk4s1",
            deviceNode: "/dev/disk4s1",
            volumeName: "Passport",
            mediaName: "Passport",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: nil,
            isMounted: false,
            isWritable: false,
            isInternal: false
        )

        let optionSets = config.readOnlyOptionSets(for: volume, user: ConsoleUser(uid: 501, gid: 20))
        let firstOptions = optionSets[0].joined(separator: ",")
        XCTAssertTrue(firstOptions.contains("uid=501"))
        XCTAssertTrue(firstOptions.contains("gid=20"))
        XCTAssertTrue(firstOptions.contains("allow_other"))
        XCTAssertTrue(firstOptions.contains("ro"))
        XCTAssertTrue(firstOptions.contains("volname=Passport"))
        XCTAssertTrue(firstOptions.contains("local"))
    }
}
