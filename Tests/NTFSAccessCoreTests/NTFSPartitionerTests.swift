@testable import NTFSAccessCore
import XCTest

final class NTFSPartitionerTests: XCTestCase {
    func testBuildsEqualSizedNTFSAccessPartitionDiskArguments() throws {
        let request = try NTFSPartitionRequest(
            wholeDisk: "/dev/disk13",
            volumeNames: ["HP_NTFS_A", "HP_NTFS_B"]
        )

        XCTAssertEqual(request.normalizedWholeDisk, "disk13")
        XCTAssertEqual(request.diskutilArguments(), [
            "partitionDisk",
            "/dev/disk13",
            "GPT",
            "NTFS Access",
            "HP_NTFS_A",
            "50%",
            "NTFS Access",
            "HP_NTFS_B",
            "R"
        ])
    }

    func testRejectsPartitionDeviceInsteadOfWholeDisk() {
        XCTAssertThrowsError(
            try NTFSPartitionRequest(wholeDisk: "/dev/disk13s2", volumeNames: ["A", "B"])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("whole disk"))
        }
    }

    func testRejectsSingleVolumeRequest() {
        XCTAssertThrowsError(
            try NTFSPartitionRequest(wholeDisk: "/dev/disk13", volumeNames: ["Only"])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("at least two"))
        }
    }

    func testRejectsUnsafeVolumeNames() {
        XCTAssertThrowsError(
            try NTFSPartitionRequest(wholeDisk: "/dev/disk13", volumeNames: ["Good", "../Bad"])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("letters, numbers"))
        }
    }

    func testDryRunSummaryReportsWrongDiskEvidenceAndTypedConfirmation() throws {
        let request = try NTFSPartitionRequest(wholeDisk: "/dev/disk13", volumeNames: ["A", "B"])
        let partitioner = NTFSPartitioner(commandRunner: Self.fakeDiskutilRunner())

        let summary = try partitioner.dryRunSummary(request: request)

        XCTAssertEqual(summary.deviceIdentifier, "disk13")
        XCTAssertEqual(summary.deviceNode, "/dev/disk13")
        XCTAssertEqual(summary.mediaName, "HP v115w")
        XCTAssertEqual(summary.sizeBytes, 4_000_000_000)
        XCTAssertEqual(summary.protocolName, "USB")
        XCTAssertFalse(summary.isInternal)
        XCTAssertEqual(summary.isRemovable, true)
        XCTAssertEqual(summary.isEjectable, true)
        XCTAssertFalse(summary.isReadOnly)
        XCTAssertEqual(summary.confirmationPhrase, "ERASE disk13")
        XCTAssertTrue(summary.humanReadableLines.joined(separator: "\n").contains("Current partition map"))
        XCTAssertTrue(summary.humanReadableLines.joined(separator: "\n").contains("/dev/disk13"))
    }

    func testDryRunAcceptsModernDiskutilWholeDiskAndWritableMediaKeys() throws {
        let request = try NTFSPartitionRequest(wholeDisk: "/dev/disk13", volumeNames: ["A", "B"])
        let partitioner = NTFSPartitioner(commandRunner: Self.fakeDiskutilRunner(useWholeDiskKey: true, useWritableMediaKey: true))

        let summary = try partitioner.dryRunSummary(request: request)

        XCTAssertEqual(summary.deviceIdentifier, "disk13")
        XCTAssertFalse(summary.isInternal)
        XCTAssertFalse(summary.isReadOnly)
    }

    func testPartitionRequiresTypedConfirmation() throws {
        let request = try NTFSPartitionRequest(wholeDisk: "/dev/disk13", volumeNames: ["A", "B"])
        let partitioner = NTFSPartitioner(commandRunner: Self.fakeDiskutilRunner())

        XCTAssertThrowsError(try partitioner.partition(request: request, confirmation: "YES")) { error in
            XCTAssertTrue(error.localizedDescription.contains("ERASE disk13"))
        }
    }

    func testPartitionReReadsIdentityBeforeDestructiveErase() throws {
        let request = try NTFSPartitionRequest(wholeDisk: "/dev/disk13", volumeNames: ["A", "B"])
        var infoCalls = 0
        var partitionDiskWasCalled = false
        let partitioner = NTFSPartitioner { executable, arguments, _, _ in
            if executable == "/usr/sbin/diskutil", arguments == ["info", "-plist", "/dev/disk13"] {
                infoCalls += 1
                let mediaName = infoCalls == 1 ? "HP v115w" : "Different Disk"
                return ShellResult(status: 0, stdout: Self.diskInfoPlist(mediaName: mediaName), stderr: "")
            }
            if executable == "/usr/sbin/diskutil", arguments == ["list", "/dev/disk13"] {
                return ShellResult(status: 0, stdout: "/dev/disk13 partition map\n", stderr: "")
            }
            if executable == "/usr/sbin/diskutil", arguments.first == "partitionDisk" {
                partitionDiskWasCalled = true
                return ShellResult(status: 0, stdout: "erased", stderr: "")
            }
            XCTFail("Unexpected command: \(executable) \(arguments)")
            return ShellResult(status: 127, stdout: "", stderr: "unexpected")
        }

        XCTAssertThrowsError(try partitioner.partition(request: request, confirmation: "ERASE disk13")) { error in
            XCTAssertTrue(error.localizedDescription.contains("identity changed"))
        }
        XCTAssertFalse(partitionDiskWasCalled)
    }

    func testPartitionRunsAfterCorrectConfirmationAndStableIdentity() throws {
        let request = try NTFSPartitionRequest(wholeDisk: "/dev/disk13", volumeNames: ["A", "B"])
        var partitionDiskArguments: [String]?
        let partitioner = NTFSPartitioner { executable, arguments, _, _ in
            if executable == "/usr/sbin/diskutil", arguments == ["info", "-plist", "/dev/disk13"] {
                return ShellResult(status: 0, stdout: Self.diskInfoPlist(), stderr: "")
            }
            if executable == "/usr/sbin/diskutil", arguments == ["list", "/dev/disk13"] {
                return ShellResult(status: 0, stdout: "/dev/disk13 partition map\n", stderr: "")
            }
            if executable == "/usr/sbin/diskutil", arguments.first == "partitionDisk" {
                partitionDiskArguments = arguments
                return ShellResult(status: 0, stdout: "erased", stderr: "")
            }
            XCTFail("Unexpected command: \(executable) \(arguments)")
            return ShellResult(status: 127, stdout: "", stderr: "unexpected")
        }

        let result = try partitioner.partition(request: request, confirmation: "ERASE disk13")

        XCTAssertEqual(result.stdoutTrimmed, "erased")
        XCTAssertEqual(partitionDiskArguments, request.diskutilArguments())
    }

    func testPartitionRejectsInternalDiskFromDiskutilInfo() throws {
        let request = try NTFSPartitionRequest(wholeDisk: "/dev/disk0", volumeNames: ["A", "B"])
        let partitioner = NTFSPartitioner(commandRunner: Self.fakeDiskutilRunner(isInternal: true))

        XCTAssertThrowsError(try partitioner.dryRunSummary(request: request)) { error in
            XCTAssertTrue(error.localizedDescription.contains("internal"))
        }
    }

    private static func fakeDiskutilRunner(
        mediaName: String = "HP v115w",
        isInternal: Bool = false,
        isReadOnly: Bool = false,
        useWholeDiskKey: Bool = false,
        useWritableMediaKey: Bool = false
    ) -> NTFSPartitioner.CommandRunner {
        { executable, arguments, _, _ in
            if executable == "/usr/sbin/diskutil", arguments.contains("info") {
                return ShellResult(
                    status: 0,
                    stdout: diskInfoPlist(
                        mediaName: mediaName,
                        isInternal: isInternal,
                        isReadOnly: isReadOnly,
                        useWholeDiskKey: useWholeDiskKey,
                        useWritableMediaKey: useWritableMediaKey
                    ),
                    stderr: ""
                )
            }
            if executable == "/usr/sbin/diskutil", arguments.contains("list") {
                return ShellResult(status: 0, stdout: "/dev/disk13 partition map\n", stderr: "")
            }
            if executable == "/usr/sbin/diskutil", arguments.first == "partitionDisk" {
                return ShellResult(status: 0, stdout: "partitioned", stderr: "")
            }
            XCTFail("Unexpected command: \(executable) \(arguments)")
            return ShellResult(status: 127, stdout: "", stderr: "unexpected")
        }
    }

    private static func diskInfoPlist(
        mediaName: String = "HP v115w",
        isInternal: Bool = false,
        isReadOnly: Bool = false,
        useWholeDiskKey: Bool = false,
        useWritableMediaKey: Bool = false
    ) -> String {
        let wholeDiskKey = useWholeDiskKey ? "WholeDisk" : "Whole"
        let readOnlyKey = useWritableMediaKey ? "WritableMedia" : "MediaReadOnly"
        let readOnlyValue = useWritableMediaKey ? !isReadOnly : isReadOnly
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>DeviceIdentifier</key><string>disk13</string>
          <key>DeviceNode</key><string>/dev/disk13</string>
          <key>MediaName</key><string>\(mediaName)</string>
          <key>TotalSize</key><integer>4000000000</integer>
          <key>BusProtocol</key><string>USB</string>
          <key>\(wholeDiskKey)</key><true/>
          <key>Internal</key><\(isInternal ? "true" : "false")/>
          <key>Removable</key><true/>
          <key>Ejectable</key><true/>
          <key>\(readOnlyKey)</key><\(readOnlyValue ? "true" : "false")/>
        </dict>
        </plist>
        """
    }
}
