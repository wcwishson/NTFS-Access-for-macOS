import Darwin
import Foundation

@MainActor
final class AppLaunchPreferences {
    static let shared = AppLaunchPreferences()

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let launchAgentLabel = "com.ntfsaccess.menu"
    private let launchAgentPlistPath = "/Library/LaunchAgents/com.ntfsaccess.menu.plist"
    private let startMinimizedKey = "StartMinimizedAtLogin"

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    var startMinimized: Bool {
        get {
            guard defaults.object(forKey: startMinimizedKey) != nil else {
                return true
            }
            return defaults.bool(forKey: startMinimizedKey)
        }
        set {
            defaults.set(newValue, forKey: startMinimizedKey)
        }
    }

    func isStartWithMacEnabled() -> Bool {
        guard fileManager.fileExists(atPath: launchAgentPlistPath) else {
            return false
        }

        guard let output = try? runLaunchctl(["print-disabled", launchAgentDomain]) else {
            return true
        }

        return disabledState(from: output).map { !$0 } ?? true
    }

    func setStartWithMacEnabled(_ enabled: Bool) throws {
        guard fileManager.fileExists(atPath: launchAgentPlistPath) else {
            throw LaunchPreferenceError.launchAgentMissing
        }

        let command = enabled ? "enable" : "disable"
        _ = try runLaunchctl([command, "\(launchAgentDomain)/\(launchAgentLabel)"])
    }

    private var launchAgentDomain: String {
        "gui/\(getuid())"
    }

    private func disabledState(from output: String) -> Bool? {
        let escapedLabel = NSRegularExpression.escapedPattern(for: launchAgentLabel)
        let pattern = "\"\(escapedLabel)\"\\s*=>\\s*(true|false|enabled|disabled)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges == 2,
              let valueRange = Range(match.range(at: 1), in: output) else {
            return nil
        }

        switch output[valueRange] {
        case "true", "disabled":
            return true
        case "false", "enabled":
            return false
        default:
            return nil
        }
    }

    private func runLaunchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw LaunchPreferenceError.launchctlFailed(arguments: arguments, stderr: error, stdout: output)
        }

        return output
    }
}

private enum LaunchPreferenceError: LocalizedError {
    case launchAgentMissing
    case launchctlFailed(arguments: [String], stderr: String, stdout: String)

    var errorDescription: String? {
        switch self {
        case .launchAgentMissing:
            return "The NTFS Access login item is not installed. Reinstall NTFS Access, then try again."
        case .launchctlFailed(let arguments, let stderr, let stdout):
            let detail = stderr.isEmpty ? stdout : stderr
            let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDetail.isEmpty else {
                return "launchctl \(arguments.joined(separator: " ")) failed."
            }
            return "launchctl \(arguments.joined(separator: " ")) failed: \(trimmedDetail)"
        }
    }
}
