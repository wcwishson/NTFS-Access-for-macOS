@testable import NTFSAccessCore
import Darwin
import XCTest

final class ShellTests: XCTestCase {
    func testTimeoutReapsProcessThatIgnoresTerminate() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsaccess-shell-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pidFile = temporaryDirectory.appendingPathComponent("pid")
        let script = temporaryDirectory.appendingPathComponent("ignore-term.sh")
        try """
        #!/bin/sh
        echo $$ > "$1"
        trap '' TERM
        while :; do
          sleep 1
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        XCTAssertThrowsError(try Shell.run("/bin/sh", [script.path, pidFile.path], timeout: 0.2)) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }

        let pid = try readPID(from: pidFile)
        defer { kill(pid, SIGKILL) }

        eventually(timeout: 2) {
            !Self.processExists(pid)
        }
    }

    private func readPID(from url: URL) throws -> pid_t {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw AppError(message: "Timed out waiting for child pid file")
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func eventually(timeout: TimeInterval, predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(predicate())
    }
}
