// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NTFSAccess",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "NTFSAccessShared", targets: ["NTFSAccessShared"]),
        .library(name: "NTFSAccessCore", targets: ["NTFSAccessCore"]),
        .executable(name: "mountd", targets: ["mountd"]),
        .executable(name: "mount_ntfsaccess", targets: ["mount_ntfsaccess"]),
        .executable(name: "ntfsaccessctl", targets: ["ntfsaccessctl"]),
        .executable(name: "NTFSMenuApp", targets: ["NTFSMenuApp"]),
        .executable(name: "newfs_ntfsaccess", targets: ["newfs_ntfsaccess"])
    ],
    targets: [
        .target(
            name: "NTFSAccessShared"
        ),
        .target(
            name: "NTFSAccessCore",
            dependencies: ["NTFSAccessShared"]
        ),
        .target(
            name: "NTFSMountDaemonCore",
            dependencies: ["NTFSAccessCore", "NTFSAccessShared"]
        ),
        .executableTarget(
            name: "mountd",
            dependencies: ["NTFSMountDaemonCore"]
        ),
        .executableTarget(
            name: "mount_ntfsaccess",
            dependencies: ["NTFSMountDaemonCore"]
        ),
        .executableTarget(
            name: "ntfsaccessctl",
            dependencies: ["NTFSAccessCore", "NTFSAccessShared"]
        ),
        .executableTarget(
            name: "NTFSMenuApp",
            dependencies: ["NTFSMountDaemonCore", "NTFSAccessShared"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "newfs_ntfsaccess",
            dependencies: ["NTFSAccessCore"]
        ),
        .testTarget(
            name: "NTFSAccessCoreTests",
            dependencies: ["NTFSAccessCore", "NTFSAccessShared", "NTFSMountDaemonCore"]
        )
    ]
)
