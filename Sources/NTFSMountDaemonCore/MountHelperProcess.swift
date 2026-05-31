import Darwin
import Foundation
import NTFSAccessCore

public enum MountHelperProcess {
    static let rawDiskPermissionDeniedStatus: Int32 = 75
    static let mountAttemptTimeoutStatus: Int32 = 124
    static let defaultMountAttemptTimeout: TimeInterval = 90
    private static let forwardedOutputLimit = 256

    public static func run(arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else {
            fputs("usage: NTFSMenuApp --mount-helper <device> <mountpoint> [fixed|removable] [readonly|writable] [suid|nosuid] [dev|nodev]\n", stderr)
            return 64
        }

        let device = normalizeDevice(arguments[0])
        let mountPoint = arguments[1]
        let flags = Array(arguments.dropFirst(2))
        let requestedVolumeName = volumeName(from: flags) ?? derivedVolumeName(for: device)

        guard let ntfs3gPath = resolveToolPath(named: "ntfs-3g") else {
            fputs("NTFS Access mount helper: ntfs-3g not found in the app bundle or managed /Library toolchain\n", stderr)
            return 72
        }

        do {
            try prepareMountPoint(mountPoint)
        } catch {
            fputs("NTFS Access mount helper: cannot prepare mount point \(mountPoint): \(error.localizedDescription)\n", stderr)
            return 73
        }

        return runResolved(
            ntfs3gPath: ntfs3gPath,
            device: device,
            mountPoint: mountPoint,
            flags: flags,
            requestedVolumeName: requestedVolumeName,
            user: ConsoleUser.current(),
            durabilityMode: DaemonSettingsStore().load().durabilityMode
        )
    }

    static func runResolved(
        ntfs3gPath: String,
        device: String,
        mountPoint: String,
        flags: [String],
        requestedVolumeName: String?,
        user: ConsoleUser,
        durabilityMode: MountDurabilityMode = .performance,
        mountAttemptTimeout: TimeInterval = defaultMountAttemptTimeout,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Int32 {
        let writeOptionSets = mountOptionSets(
            user: user,
            readOnly: false,
            volumeName: requestedVolumeName,
            durabilityMode: durabilityMode
        )
        let readOnlyOptionSets = mountOptionSets(user: user, readOnly: true, volumeName: requestedVolumeName)
        let candidates = deviceCandidates(for: device, fileExists: fileExists)

        if readOnlyRequested(in: flags) {
            return runAttempts(
                ntfs3gPath: ntfs3gPath,
                devices: candidates,
                mountPoint: mountPoint,
                optionSets: readOnlyOptionSets,
                failureMessage: "NTFS Access mount helper: read-only ntfs-3g mount failed for \(device)",
                timeout: mountAttemptTimeout
            )
        }

        let writeStatus = runAttempts(
            ntfs3gPath: ntfs3gPath,
            devices: candidates,
            mountPoint: mountPoint,
            optionSets: writeOptionSets,
            failureMessage: "NTFS Access mount helper: writable ntfs-3g mount failed for \(device)",
            printFinalFailure: false,
            timeout: mountAttemptTimeout
        )
        if writeStatus == 0 {
            return 0
        }
        if writeStatus == mountAttemptTimeoutStatus {
            return writeStatus
        }
        if writeStatus == rawDiskPermissionDeniedStatus {
            return writeStatus
        }

        fputs("NTFS Access mount helper: writable mount failed for \(device), retrying read-only\n", stderr)
        return runAttempts(
            ntfs3gPath: ntfs3gPath,
            devices: candidates,
            mountPoint: mountPoint,
            optionSets: readOnlyOptionSets,
            failureMessage: "NTFS Access mount helper: read-only ntfs-3g mount failed for \(device)",
            timeout: mountAttemptTimeout
        )
    }

    static func normalizeDevice(_ raw: String) -> String {
        raw.hasPrefix("/dev/") ? raw : "/dev/\(raw)"
    }

    static func readOnlyRequested(in flags: [String]) -> Bool {
        flags.contains { flag in
            let normalized = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "readonly"
                || normalized == "rdonly"
                || normalized == "read-only"
                || normalized == "ro"
        }
    }

    static func prepareMountPoint(_ mountPoint: String) throws {
        try FileManager.default.createDirectory(
            atPath: mountPoint,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mountPoint)
    }

    static func mountOptions(user: ConsoleUser, readOnly: Bool, volumeName: String? = nil) -> [String] {
        mountOptionSets(user: user, readOnly: readOnly, volumeName: volumeName).first ?? []
    }

    static func mountOptionSets(user: ConsoleUser, readOnly: Bool, volumeName: String? = nil) -> [[String]] {
        mountOptionSets(user: user, readOnly: readOnly, volumeName: volumeName, durabilityMode: .performance)
    }

    static func mountOptionSets(
        user: ConsoleUser,
        readOnly: Bool,
        volumeName: String? = nil,
        durabilityMode: MountDurabilityMode
    ) -> [[String]] {
        if readOnly {
            return readOnlyOptionSets(user: user, volumeName: volumeName)
        }
        return readWriteOptionSets(user: user, volumeName: volumeName, durabilityMode: durabilityMode)
    }

    private static func readWriteOptionSets(
        user: ConsoleUser,
        volumeName: String?,
        durabilityMode: MountDurabilityMode
    ) -> [[String]] {
        var options = [
            "allow_other",
            "defer_permissions"
        ]
        if let volumeName = sanitizedOptionValue(volumeName) {
            options.append("volname=\(volumeName)")
        }
        let named = options
        let localNamed = named + ["local"]
        var extended = named + [
            "local",
            "auto_xattr",
            "auto_cache",
            "big_writes",
            "noatime",
            "iosize=1048576",
            "daemon_timeout=60"
        ]
        if durabilityMode == .performance {
            extended.insert(contentsOf: ["nosyncwrites", "nosynconclose"], at: extended.firstIndex(of: "iosize=1048576") ?? extended.count)
        }
        let finderCompatible = [
            "allow_other",
            "defer_permissions"
        ]

        return uniqueOptionSets([extended, localNamed, named, finderCompatible])
    }

    private static func readOnlyOptionSets(user: ConsoleUser, volumeName: String?) -> [[String]] {
        let finderCompatible = [
            "uid=\(user.uid)",
            "gid=\(user.gid)",
            "umask=022",
            "allow_other",
            "ro"
        ]
        var named = finderCompatible
        if let volumeName = sanitizedOptionValue(volumeName) {
            named.append("volname=\(volumeName)")
        }
        let localNamed = named + ["local"]
        let extended = localNamed + ["noatime"]
        let minimal = [
            "uid=\(user.uid)",
            "gid=\(user.gid)",
            "umask=022",
            "ro"
        ]

        return uniqueOptionSets([localNamed, extended, named, finderCompatible, minimal])
    }

    private static func uniqueOptionSets(_ sets: [[String]]) -> [[String]] {
        var seen = Set<String>()
        return sets.filter { options in
            seen.insert(options.joined(separator: ",")).inserted
        }
    }

    static func volumeName(from flags: [String]) -> String? {
        for flag in flags {
            let trimmed = flag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == "volname" || key == "volume-name" || key == "name" else {
                continue
            }
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func derivedVolumeName(
        for device: String,
        commandRunner: ShellCommandRunner = Shell.run
    ) -> String? {
        guard let result = try? commandRunner("/usr/sbin/diskutil", ["info", "-plist", device], [:], 8),
              result.status == 0,
              let plist = plistDictionary(from: result.stdout) else {
            return nil
        }

        return stringValue(plist, key: "VolumeName") ?? stringValue(plist, key: "MediaName")
    }

    private static func sanitizedOptionValue(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. ")
        let cleaned = String(raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")

        return cleaned.isEmpty ? nil : cleaned
    }

    static func deviceCandidates(
        for normalizedDevice: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        guard normalizedDevice.hasPrefix("/dev/disk") else {
            return [normalizedDevice]
        }

        let suffix = String(normalizedDevice.dropFirst("/dev/disk".count))
        let rawDevice = "/dev/rdisk\(suffix)"
        if fileExists(rawDevice), rawDevice != normalizedDevice {
            return [normalizedDevice, rawDevice]
        }
        return [normalizedDevice]
    }

    static func bundledToolPath(
        named binaryName: String,
        appExecutablePath: String = CommandLine.arguments[0],
        fileManager: FileManager = .default
    ) -> String? {
        let executableURL = URL(fileURLWithPath: appExecutablePath).resolvingSymlinksInPath()
        let contentsURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = contentsURL
            .appendingPathComponent("Library/NTFSAccess/toolchain/bin")
            .appendingPathComponent(binaryName)
            .path

        if fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static func managedToolPath(
        named binaryName: String,
        fileManager: FileManager = .default
    ) -> String? {
        for directory in [
            NTFSAccessPaths.managedToolchainBinPath,
            NTFSAccessPaths.managedToolchainSbinPath
        ] {
            let candidate = "\(directory)/\(binaryName)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func resolveToolPath(
        named binaryName: String,
        appExecutablePath: String = CommandLine.arguments[0],
        fileManager: FileManager = .default
    ) -> String? {
        bundledToolPath(named: binaryName, appExecutablePath: appExecutablePath, fileManager: fileManager)
            ?? managedToolPath(named: binaryName, fileManager: fileManager)
    }

    private static func plistDictionary(from output: String) -> [String: Any]? {
        let body = plistBody(from: output)
        guard let data = body.data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func plistBody(from output: String) -> String {
        guard let start = output.range(of: "<?xml") ?? output.range(of: "<plist"),
              let end = output.range(of: "</plist>", options: .backwards) else {
            return output
        }
        return String(output[start.lowerBound..<end.upperBound])
    }

    private static func stringValue(_ dictionary: [String: Any], key: String) -> String? {
        guard let raw = dictionary[key] as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func runAttempts(
        ntfs3gPath: String,
        devices: [String],
        mountPoint: String,
        optionSets: [[String]],
        failureMessage: String,
        printFinalFailure: Bool = true,
        timeout: TimeInterval = defaultMountAttemptTimeout
    ) -> Int32 {
        for device in devices {
            for options in optionSets {
                let result = runNTFS3G(ntfs3gPath: ntfs3gPath, device: device, mountPoint: mountPoint, options: options, timeout: timeout)
                if result.succeeded {
                    return 0
                }
                if result.timedOut {
                    fputs("\(failureMessage): ntfs-3g timed out\n", stderr)
                    return mountAttemptTimeoutStatus
                }
                if isRawDiskPermissionDenied(result.output) {
                    fputs("\(failureMessage): macOS denied raw disk access to \(device)\n", stderr)
                    return rawDiskPermissionDeniedStatus
                }
            }
        }

        if printFinalFailure {
            fputs("\(failureMessage)\n", stderr)
        }
        return 74
    }

    private static func runNTFS3G(ntfs3gPath: String, device: String, mountPoint: String, options: [String], timeout: TimeInterval) -> NTFS3GAttemptResult {
        let optionsValue = options.joined(separator: ",")
        fputs("NTFS Access mount helper: trying ntfs-3g device=\(device) mountpoint=\(mountPoint) options=\(optionsValue)\n", stderr)

        let stdoutURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ntfsaccess-ntfs3g-stdout-\(UUID().uuidString).log")
        let stderrURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ntfsaccess-ntfs3g-stderr-\(UUID().uuidString).log")

        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil),
              let stdoutFile = try? FileHandle(forUpdating: stdoutURL),
              let stderrFile = try? FileHandle(forUpdating: stderrURL) else {
            fputs("NTFS Access mount helper: failed to create temporary ntfs-3g output files\n", stderr)
            return NTFS3GAttemptResult(succeeded: false, output: "failed to create temporary ntfs-3g output files")
        }
        defer {
            try? stdoutFile.close()
            try? stderrFile.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ntfs3gPath)
        process.arguments = [device, mountPoint, "-o", optionsValue]
        process.standardOutput = stdoutFile
        process.standardError = stderrFile

        do {
            try process.run()
        } catch {
            fputs("NTFS Access mount helper: failed to launch ntfs-3g: \(error.localizedDescription)\n", stderr)
            return NTFS3GAttemptResult(succeeded: false, output: error.localizedDescription)
        }

        let timedOut = !waitForExit(process, timeout: timeout)
        let timeoutMessage: String
        if timedOut {
            terminateAndReap(process)
            timeoutMessage = "NTFS Access mount helper: ntfs-3g timed out after \(Int(timeout.rounded()))s"
            fputs("\(timeoutMessage)\n", stderr)
        } else {
            process.waitUntilExit()
            timeoutMessage = ""
        }

        stdoutFile.seek(toFileOffset: 0)
        stderrFile.seek(toFileOffset: 0)
        let stdoutData = stdoutFile.readDataToEndOfFile()
        let stderrData = stderrFile.readDataToEndOfFile()
        forward(stdoutData, to: .standardOutput, streamName: "stdout")
        forward(stderrData, to: .standardError, streamName: "stderr")

        let output = [
            String(data: stdoutData, encoding: .utf8),
            String(data: stderrData, encoding: .utf8),
            timeoutMessage.isEmpty ? nil : timeoutMessage
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        return NTFS3GAttemptResult(
            succeeded: !timedOut && process.terminationStatus == 0,
            output: output,
            timedOut: timedOut
        )
    }

    private static func terminateAndReap(_ process: Process) {
        process.terminate()
        _ = waitForExit(process, timeout: 0.4)

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        if waitForExit(process, timeout: 1.0) {
            process.waitUntilExit()
        }
    }

    @discardableResult
    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
    }

    private static func forward(_ data: Data, to handle: FileHandle, streamName: String) {
        guard !data.isEmpty else {
            return
        }

        let forwarded = data.prefix(forwardedOutputLimit)
        handle.write(Data(forwarded))
        if data.count > forwardedOutputLimit {
            let omitted = data.count - forwardedOutputLimit
            let notice = "\nNTFS Access mount helper: omitted \(omitted) bytes of verbose ntfs-3g \(streamName)\n"
            if let noticeData = notice.data(using: .utf8) {
                FileHandle.standardError.write(noticeData)
            }
        }
    }

    private static func isRawDiskPermissionDenied(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        let mentionsDeviceNode = lowercased.contains("/dev/disk") || lowercased.contains("/dev/rdisk")
        let denied = lowercased.contains("operation not permitted") || lowercased.contains("permission denied")
        return mentionsDeviceNode && denied
    }
}

private struct NTFS3GAttemptResult {
    let succeeded: Bool
    let output: String
    var timedOut: Bool = false
}
