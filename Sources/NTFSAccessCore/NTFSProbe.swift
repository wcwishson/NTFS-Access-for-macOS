import Foundation

public struct ProbeResult {
    public let safeForWrite: Bool
    public let reason: String
}

public protocol WriteSafetyProbing {
    func checkWriteSafety(deviceNode: String) -> ProbeResult
}

public final class NTFSProbe: WriteSafetyProbing {
    private let probePath: String?
    private let commandRunner: ShellCommandRunner
    private let transientFailureMarkers = [
        "resource busy",
        "device busy",
        "timed out",
        "timeout",
        "not responding"
    ]

    public init(
        probePath: String? = DependencyChecker.resolveNTFS3GProbePath(),
        commandRunner: @escaping ShellCommandRunner = Shell.run
    ) {
        self.probePath = probePath
        self.commandRunner = commandRunner
    }

    public func checkWriteSafety(deviceNode: String) -> ProbeResult {
        guard let probePath else {
            return ProbeResult(
                safeForWrite: false,
                reason: "ntfs-3g.probe not available; refusing writable mount without safety check"
            )
        }

        let maxAttempts = 3
        var lastMessage = "write probe reported unsafe state"

        for attempt in 1...maxAttempts {
            do {
                let result = try commandRunner(probePath, ["--readwrite", deviceNode], [:], 12)
                if result.status == 0 {
                    return ProbeResult(safeForWrite: true, reason: "write probe passed")
                }

                let message = nonEmptyMessage(result.stderrTrimmed, fallback: result.stdoutTrimmed, defaultValue: "write probe reported unsafe state")
                lastMessage = message
                if isRawDiskAccessDenied(message) {
                    return ProbeResult(safeForWrite: false, reason: message)
                }
                if attempt < maxAttempts && isTransientFailure(message) {
                    Thread.sleep(forTimeInterval: 0.5 * Double(attempt))
                    continue
                }
                return ProbeResult(safeForWrite: false, reason: message)
            } catch {
                let message = "write probe failed: \(error.localizedDescription)"
                lastMessage = message
                if isRawDiskAccessDenied(message) {
                    return ProbeResult(safeForWrite: false, reason: message)
                }
                if attempt < maxAttempts && isTransientFailure(message) {
                    Thread.sleep(forTimeInterval: 0.5 * Double(attempt))
                    continue
                }
                return ProbeResult(safeForWrite: false, reason: message)
            }
        }

        return ProbeResult(safeForWrite: false, reason: lastMessage)
    }

    private func nonEmptyMessage(_ primary: String, fallback: String, defaultValue: String) -> String {
        if !primary.isEmpty {
            return primary
        }
        if !fallback.isEmpty {
            return fallback
        }
        return defaultValue
    }

    private func isTransientFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return transientFailureMarkers.contains { lowered.contains($0) }
    }

    private func isRawDiskAccessDenied(_ message: String) -> Bool {
        let lowered = message.lowercased()
        let mentionsDisk = lowered.contains("/dev/disk") || lowered.contains("/dev/rdisk")
        let denied = lowered.contains("operation not permitted") || lowered.contains("permission denied")
        return mentionsDisk && denied
    }
}
