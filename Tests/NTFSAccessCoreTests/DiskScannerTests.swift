@testable import NTFSAccessCore
import XCTest

final class DiskScannerTests: XCTestCase {
    func testParseDiskVolumeRecognizesNTFS() {
        let scanner = DiskScanner()
        let plist: [String: Any] = [
            "DeviceIdentifier": "disk2s1",
            "DeviceNode": "/dev/disk2s1",
            "DiskUUID": "2D253235-C29F-4EDA-B308-13F6DB9DA6DD",
            "ParentWholeDisk": "disk2",
            "PartitionMapPartitionOffset": 210_763_776,
            "VolumeSize": 128_109_768_704,
            "VolumeName": "Data",
            "MediaName": "Data",
            "FilesystemType": "ntfs",
            "FilesystemName": "Windows NT Filesystem",
            "Mounted": true,
            "Writable": true,
            "Internal": false,
            "MountPoint": "/Volumes/Data"
        ]

        let volume = scanner.parseDiskVolume(plist, fallbackIdentifier: "disk2s1")
        XCTAssertEqual(volume.deviceIdentifier, "disk2s1")
        XCTAssertEqual(volume.stableIdentity, "diskuuid-2D253235-C29F-4EDA-B308-13F6DB9DA6DD")
        XCTAssertEqual(volume.diskUUID, "2D253235-C29F-4EDA-B308-13F6DB9DA6DD")
        XCTAssertEqual(volume.parentWholeDisk, "disk2")
        XCTAssertEqual(volume.partitionMapPartitionOffset, 210_763_776)
        XCTAssertEqual(volume.size, 128_109_768_704)
        XCTAssertTrue(volume.isNTFS)
        XCTAssertTrue(volume.isExternal)
        XCTAssertTrue(volume.isMounted)
        XCTAssertTrue(volume.isWritable)
        XCTAssertEqual(volume.mountPoint, "/Volumes/Data")
    }

    func testParseDiskVolumeDoesNotTrustWritableFlagWithoutMountPoint() {
        let scanner = DiskScanner()
        let plist: [String: Any] = [
            "DeviceIdentifier": "disk12s1",
            "DeviceNode": "/dev/disk12s1",
            "VolumeName": "NTFS_STRESS",
            "MediaName": "NTFS_STRESS",
            "FilesystemType": "ntfs",
            "FilesystemName": "Windows NT Filesystem",
            "Mounted": true,
            "Writable": true,
            "Internal": false,
            "MountPoint": ""
        ]

        let volume = scanner.parseDiskVolume(plist, fallbackIdentifier: "disk12s1")

        XCTAssertFalse(volume.isMounted)
        XCTAssertFalse(volume.isWritable)
        XCTAssertNil(volume.mountPoint)
    }

    func testParseDiskListVolumesKeepsMountedFallbackWritableUnknown() {
        let scanner = DiskScanner()
        let plist: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk12",
                    "Content": "FDisk_partition_scheme",
                    "OSInternal": false,
                    "Partitions": [
                        [
                            "Content": "Windows_NTFS",
                            "DeviceIdentifier": "disk12s1",
                            "MountPoint": "/Volumes/NTFSAccess-disk12s1",
                            "VolumeName": "NTFS_STRESS",
                            "Size": 128_319_488_000
                        ]
                    ]
                ]
            ]
        ]

        let volumes = scanner.parseDiskListVolumes(plist)

        XCTAssertEqual(volumes.count, 1)
        XCTAssertEqual(volumes.first?.deviceIdentifier, "disk12s1")
        XCTAssertEqual(volumes.first?.volumeName, "NTFS_STRESS")
        XCTAssertEqual(volumes.first?.mountPoint, "/Volumes/NTFSAccess-disk12s1")
        XCTAssertTrue(volumes.first?.isNTFS == true)
        XCTAssertTrue(volumes.first?.isMounted == true)
        XCTAssertFalse(volumes.first?.isWritable == true)
        XCTAssertTrue(volumes.first?.isExternal == true)
    }

    func testParseDiskListVolumesCarriesPhysicalDriveNameToPartitions() {
        let scanner = DiskScanner()
        let plist: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk13",
                    "MediaName": "ESD-S1C",
                    "IORegistryEntryName": "ROG ESD-S1C Media",
                    "Content": "GUID_partition_scheme",
                    "OSInternal": false,
                    "Partitions": [
                        [
                            "Content": "Windows_NTFS",
                            "DeviceIdentifier": "disk13s2",
                            "MountPoint": "/Volumes/NVME A",
                            "VolumeName": "NVME A",
                            "Size": 337_988_550_656
                        ],
                        [
                            "Content": "Windows_NTFS",
                            "DeviceIdentifier": "disk13s3",
                            "MountPoint": "/Volumes/NVME B",
                            "VolumeName": "NVME B",
                            "Size": 337_988_550_656
                        ]
                    ]
                ]
            ]
        ]

        let volumes = scanner.parseDiskListVolumes(plist)

        XCTAssertEqual(volumes.map(\.deviceIdentifier), ["disk13s2", "disk13s3"])
        XCTAssertEqual(volumes.map(\.parentWholeDisk), ["disk13", "disk13"])
        XCTAssertEqual(volumes.map(\.parentWholeDiskName), ["ESD-S1C", "ESD-S1C"])
    }

    func testPartitionInfoDoesNotTreatUntitledIORegistryNameAsPhysicalDriveName() {
        let scanner = DiskScanner()
        let plist: [String: Any] = [
            "DeviceIdentifier": "disk13s2",
            "DeviceNode": "/dev/disk13s2",
            "DiskUUID": "4C0C0133-D379-45D1-ADDA-7BA72266BB22",
            "ParentWholeDisk": "disk13",
            "PartitionMapPartition": true,
            "VolumeName": "NVME A",
            "MediaName": "",
            "IORegistryEntryName": "Untitled 2",
            "FilesystemType": "ntfs",
            "FilesystemName": "Windows NT Filesystem",
            "Mounted": true,
            "Writable": true,
            "Internal": false,
            "MountPoint": "/Volumes/NTFSAccess-diskuuid-4C0C0133-D379-45D1-ADDA-7BA72266BB22"
        ]

        let fallback = DiskVolume(
            deviceIdentifier: "disk13s2",
            deviceNode: "/dev/disk13s2",
            parentWholeDisk: "disk13",
            parentWholeDiskName: "ESD-S1C",
            volumeName: "NVME A",
            mediaName: "NVME A",
            filesystemType: "ntfs",
            filesystemName: "Windows NT Filesystem",
            mountPoint: "/Volumes/NVME A",
            isMounted: true,
            isWritable: false,
            isInternal: false
        )

        let volume = scanner.parseDiskVolume(plist, fallbackIdentifier: "disk13s2")
            .mergingPhysicalDriveMetadata(from: fallback)

        XCTAssertEqual(volume.parentWholeDisk, "disk13")
        XCTAssertEqual(volume.parentWholeDiskName, "ESD-S1C")
    }

    func testDiskListFallsBackToParentIdentifierWhenWholeDiskNameIsMissing() {
        let scanner = DiskScanner()
        let plist: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk13",
                    "Content": "GUID_partition_scheme",
                    "OSInternal": false,
                    "Partitions": [
                        [
                            "Content": "Windows_NTFS",
                            "DeviceIdentifier": "disk13s2",
                            "MountPoint": "/Volumes/NVME A",
                            "VolumeName": "NVME A",
                            "Size": 337_988_550_656
                        ],
                        [
                            "Content": "Windows_NTFS",
                            "DeviceIdentifier": "disk13s3",
                            "MountPoint": "/Volumes/NVME B",
                            "VolumeName": "NVME B",
                            "Size": 337_988_550_656
                        ]
                    ]
                ]
            ]
        ]

        let volumes = scanner.parseDiskListVolumes(plist)

        XCTAssertEqual(volumes.map(\.parentWholeDiskName), ["disk13", "disk13"])
    }

    func testRealScanEnrichesDiskListFallbackNameFromWholeDiskInfo() throws {
        var infoRequests: [String] = []
        let scanner = DiskScanner { arguments, _, _ in
            if arguments == ["list", "-plist"] {
                return [
                    "AllDisksAndPartitions": [
                        [
                            "DeviceIdentifier": "disk13",
                            "Content": "GUID_partition_scheme",
                            "OSInternal": false,
                            "Partitions": [
                                [
                                    "Content": "Windows_NTFS",
                                    "DeviceIdentifier": "disk13s2",
                                    "MountPoint": "/Volumes/NVME A",
                                    "VolumeName": "NVME A",
                                    "Size": 337_988_550_656
                                ],
                                [
                                    "Content": "Windows_NTFS",
                                    "DeviceIdentifier": "disk13s3",
                                    "MountPoint": "/Volumes/NVME B",
                                    "VolumeName": "NVME B",
                                    "Size": 337_988_550_656
                                ]
                            ]
                        ]
                    ]
                ]
            }

            if arguments == ["info", "-plist", "/dev/disk13"] {
                infoRequests.append("disk13")
                return [
                    "DeviceIdentifier": "disk13",
                    "DeviceNode": "/dev/disk13",
                    "ParentWholeDisk": "disk13",
                    "MediaName": "ESD-S1C",
                    "IORegistryEntryName": "ROG ESD-S1C Media",
                    "WholeDisk": true,
                    "Internal": false
                ]
            }

            if arguments == ["info", "-plist", "/dev/disk13s2"] || arguments == ["info", "-plist", "/dev/disk13s3"] {
                let identifier = String(arguments[2].dropFirst("/dev/".count))
                infoRequests.append(identifier)
                return [
                    "DeviceIdentifier": identifier,
                    "DeviceNode": arguments[2],
                    "DiskUUID": "\(identifier)-uuid",
                    "ParentWholeDisk": "disk13",
                    "PartitionMapPartition": true,
                    "VolumeName": identifier == "disk13s2" ? "NVME A" : "NVME B",
                    "MediaName": "",
                    "IORegistryEntryName": identifier == "disk13s2" ? "Untitled 2" : "Untitled 3",
                    "FilesystemType": "ntfs",
                    "FilesystemName": "Windows NT Filesystem",
                    "Mounted": true,
                    "Writable": true,
                    "Internal": false,
                    "MountPoint": "/Volumes/\(identifier)"
                ]
            }

            throw AppError(message: "unexpected diskutil arguments: \(arguments)")
        }

        let volumes = try scanner.listNTFSVolumes(externalOnly: true)

        XCTAssertEqual(volumes.map(\.parentWholeDiskName), ["ESD-S1C", "ESD-S1C"])
        XCTAssertEqual(infoRequests, ["disk13", "disk13s2", "disk13s3"])
    }

    func testRealScanEnrichesPartitionInfoWhenDiskListOnlyShowsMicrosoftBasicData() throws {
        var infoRequests: [String] = []
        let scanner = DiskScanner { arguments, _, _ in
            if arguments == ["list", "-plist"] {
                return [
                    "AllDisksAndPartitions": [
                        [
                            "DeviceIdentifier": "disk13",
                            "Content": "GUID_partition_scheme",
                            "OSInternal": false,
                            "Partitions": [
                                [
                                    "Content": "Microsoft Basic Data",
                                    "DeviceIdentifier": "disk13s2",
                                    "MountPoint": "/Volumes/NTFSAccess-diskuuid-4C0C0133",
                                    "VolumeName": "NVME A",
                                    "Size": 337_988_550_656
                                ]
                            ]
                        ]
                    ]
                ]
            }

            if arguments == ["info", "-plist", "/dev/disk13"] {
                infoRequests.append("disk13")
                return [
                    "DeviceIdentifier": "disk13",
                    "DeviceNode": "/dev/disk13",
                    "ParentWholeDisk": "disk13",
                    "MediaName": "ESD-S1C",
                    "IORegistryEntryName": "ROG ESD-S1C Media",
                    "WholeDisk": true,
                    "Internal": false
                ]
            }

            if arguments == ["info", "-plist", "/dev/disk13s2"] {
                infoRequests.append("disk13s2")
                return [
                    "DeviceIdentifier": "disk13s2",
                    "DeviceNode": "/dev/disk13s2",
                    "DiskUUID": "4C0C0133-D379-45D1-ADDA-7BA72266BB22",
                    "ParentWholeDisk": "disk13",
                    "PartitionMapPartition": true,
                    "VolumeName": "NVME A",
                    "MediaName": "",
                    "IORegistryEntryName": "Untitled 2",
                    "FilesystemType": "ntfsaccess",
                    "FilesystemName": "NTFS Access",
                    "Mounted": true,
                    "Writable": true,
                    "Internal": false,
                    "MountPoint": "/Volumes/NTFSAccess-diskuuid-4C0C0133"
                ]
            }

            throw AppError(message: "unexpected diskutil arguments: \(arguments)")
        }

        let volumes = try scanner.listNTFSVolumes(externalOnly: true)

        XCTAssertEqual(volumes.map(\.deviceIdentifier), ["disk13s2"])
        XCTAssertEqual(volumes.map(\.parentWholeDiskName), ["ESD-S1C"])
        XCTAssertEqual(infoRequests, ["disk13s2", "disk13"])
    }

    func testParsePlistDictionaryIgnoresLeadingNoise() throws {
        let scanner = DiskScanner()
        let noisyOutput = """
        2026-05-16 noisy storage log
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DeviceIdentifier</key>
            <string>disk12s1</string>
        </dict>
        </plist>
        trailing noise
        """

        let plist = try scanner.parsePlistDictionary(from: noisyOutput)

        XCTAssertEqual(plist?["DeviceIdentifier"] as? String, "disk12s1")
    }

    func testDevDirectoryFallbackKeepsOnlyRealPartitionIdentifiers() {
        let scanner = DiskScanner()

        let identifiers = scanner.partitionIdentifiers(fromDevDirectoryEntries: [
            "disk0",
            "disk0s1",
            "disk3s1s1",
            "rdisk0s1",
            "disk13s2",
            "disk13s3",
            "console",
            "random"
        ])

        XCTAssertEqual(identifiers, ["disk0s1", "disk13s2", "disk13s3"])
    }

    func testDiskListIdentifiersKeepOnlyRealPartitionIdentifiers() {
        let scanner = DiskScanner()

        let identifiers = scanner.partitionIdentifiers(fromDiskListIdentifiers: [
            "disk12",
            "disk12s1",
            "disk13",
            "disk13s1",
            "disk13s2",
            "disk13s3",
            "disk3s1s1"
        ])

        XCTAssertEqual(identifiers, ["disk12s1", "disk13s1", "disk13s2", "disk13s3"])
        XCTAssertFalse(identifiers.contains("disk12"))
        XCTAssertFalse(identifiers.contains("disk13"))
        XCTAssertFalse(identifiers.contains("disk3s1s1"))
    }

    func testAllPartitionIdentifiersPreferGlobalPartitionTreeOverWholeDiskLookup() {
        let scanner = DiskScanner()
        let plist: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk12",
                    "Partitions": [
                        ["DeviceIdentifier": "disk12s1"]
                    ]
                ],
                [
                    "DeviceIdentifier": "disk13",
                    "Partitions": [
                        ["DeviceIdentifier": "disk13s1"],
                        ["DeviceIdentifier": "disk13s2"],
                        ["DeviceIdentifier": "disk13s3"]
                    ]
                ]
            ],
            "WholeDisks": ["disk12", "disk13"]
        ]

        let identifiers = scanner.allPartitionIdentifiers(from: plist)

        XCTAssertEqual(identifiers, ["disk12s1", "disk13s1", "disk13s2", "disk13s3"])
    }

    func testDiskScannerHasDevDirectoryFallbackWhenGlobalDiskutilListGlitches() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessCore/DiskScanner.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("direct /dev partition scan"))
        XCTAssertTrue(source.contains("contentsOfDirectory(atPath: \"/dev\")"))
        XCTAssertTrue(source.contains("fallbackVolumesOnListFailure"))
        XCTAssertTrue(source.contains("catch let fallbackError"))
        XCTAssertTrue(source.contains("Returning"))
    }

    func testDiskScannerFallsBackToGlobalPartitionsWhenOneWholeDiskLookupGlitches() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessCore/DiskScanner.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("wholeDiskLookupFailed"))
        XCTAssertTrue(source.contains("falling back to global disk list entries"))
        XCTAssertTrue(source.contains("identifiers.formUnion(output)"))
    }

    func testDiskScannerDoesNotRetryDiskutilInfoAfterTimeout() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessCore/DiskScanner.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("isDiskutilTimeout(error)"))
        XCTAssertTrue(source.contains("isLikelyInternalDeviceIdentifier(identifier)"))
        XCTAssertTrue(source.contains("sawDiskutilTimeout"))
        XCTAssertTrue(source.contains("break"))
    }

    func testDiskScannerUsesDiskListExternalHintsBeforeInfoProbeInExternalOnlyMode() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessCore/DiskScanner.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("let fallbackByIdentifier = Dictionary(uniqueKeysWithValues: fallbackVolumes.map"))
        XCTAssertTrue(source.contains("guard externalOnly, let fallbackVolume = fallbackByIdentifier[identifier] else"))
        XCTAssertTrue(source.contains("return fallbackVolume.isExternal"))
        XCTAssertTrue(source.contains("if externalOnly && !fallbackVolume.isExternal"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
