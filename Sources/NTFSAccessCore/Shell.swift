import Foundation
import Darwin

public struct ShellResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var stdoutTrimmed: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var stderrTrimmed: String {
        stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum Shell {
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String] = [:],
        timeout: TimeInterval = 30
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var resolvedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            resolvedEnvironment[key] = value
        }
        process.environment = resolvedEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AppError(message: "Failed to run command: \(executable) \(arguments.joined(separator: " ")) - \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            terminateAndReap(process)
            drainPipe(stdoutPipe)
            drainPipe(stderrPipe)
            throw AppError(message: "Command timed out: \(executable) \(arguments.joined(separator: " "))")
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return ShellResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    @discardableResult
    public static func runChecked(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String] = [:],
        timeout: TimeInterval = 30
    ) throws -> ShellResult {
        let result = try run(executable, arguments, environment: environment, timeout: timeout)
        guard result.status == 0 else {
            let detail = result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed
            throw AppError(message: "Command failed (\(result.status)): \(executable) \(arguments.joined(separator: " "))\n\(detail)")
        }
        return result
    }

    public static func which(_ executableName: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let defaults = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let candidates = Set(path.split(separator: ":").map(String.init) + defaults)

        for directory in candidates {
            let candidate = (directory as NSString).appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func terminateAndReap(_ process: Process) {
        process.terminate()

        waitForExit(process, timeout: 0.4)

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        if waitForExit(process, timeout: 1.0) {
            process.waitUntilExit()
        }
    }

    private static func drainPipe(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        _ = handle.availableData
    }

    @discardableResult
    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
    }
}
