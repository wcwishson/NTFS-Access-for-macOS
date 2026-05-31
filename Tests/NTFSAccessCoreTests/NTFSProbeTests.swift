@testable import NTFSAccessCore
import XCTest

final class NTFSProbeTests: XCTestCase {
    func testMissingProbeFailsClosedForWritableMounts() {
        let probe = NTFSProbe(probePath: nil) { _, _, _, _ in
            XCTFail("missing probe should not invoke command runner")
            return ShellResult(status: 0, stdout: "", stderr: "")
        }

        let result = probe.checkWriteSafety(deviceNode: "/dev/disk13s2")

        XCTAssertFalse(result.safeForWrite)
        XCTAssertTrue(result.reason.contains("ntfs-3g.probe not available"))
        XCTAssertTrue(result.reason.contains("refusing writable mount"))
    }

    func testRawDiskPermissionDeniedIsNotRetriedAsTransientProbeFailure() {
        var calls = 0
        let probe = NTFSProbe(probePath: "/tmp/ntfs-3g.probe") { executable, arguments, _, timeout in
            calls += 1
            XCTAssertEqual(executable, "/tmp/ntfs-3g.probe")
            XCTAssertEqual(arguments, ["--readwrite", "/dev/disk13s2"])
            XCTAssertEqual(timeout, 12)
            return ShellResult(
                status: 1,
                stdout: "",
                stderr: "Error opening '/dev/disk13s2': Operation not permitted"
            )
        }

        let result = probe.checkWriteSafety(deviceNode: "/dev/disk13s2")

        XCTAssertEqual(calls, 1)
        XCTAssertFalse(result.safeForWrite)
        XCTAssertTrue(result.reason.contains("Operation not permitted"))
    }

    func testBusyProbeFailureStillRetriesBeforeReportingUnsafe() {
        var calls = 0
        let probe = NTFSProbe(probePath: "/tmp/ntfs-3g.probe") { _, _, _, _ in
            calls += 1
            if calls < 3 {
                return ShellResult(status: 1, stdout: "", stderr: "device busy")
            }
            return ShellResult(status: 0, stdout: "", stderr: "")
        }

        let result = probe.checkWriteSafety(deviceNode: "/dev/disk13s2")

        XCTAssertEqual(calls, 3)
        XCTAssertTrue(result.safeForWrite)
    }

    func testTimeoutProbeFailureRetriesBeforeReportingUnsafe() {
        var calls = 0
        let probe = NTFSProbe(probePath: "/tmp/ntfs-3g.probe") { _, _, _, _ in
            calls += 1
            if calls < 3 {
                throw AppError(message: "Command timed out: /Library/NTFSAccess/toolchain/bin/ntfs-3g.probe")
            }
            return ShellResult(status: 0, stdout: "", stderr: "")
        }

        let result = probe.checkWriteSafety(deviceNode: "/dev/disk13s2")

        XCTAssertEqual(calls, 3)
        XCTAssertTrue(result.safeForWrite)
    }
}
