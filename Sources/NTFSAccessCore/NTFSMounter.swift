import Foundation

public protocol VolumeMounting {
    func mountReadWrite(volume: DiskVolume, user: ConsoleUser) throws -> String
    func mountReadOnly(volume: DiskVolume, user: ConsoleUser) throws -> String
    func canReadRawDevice(_ deviceNode: String) -> Bool
    func unmount(deviceIdentifier: String, mountPoint: String?, force: Bool) throws
    func mountNativeReadOnly(deviceIdentifier: String) throws
    func mountUsingRegisteredPersonality(deviceIdentifier: String, readOnly: Bool) throws
}

public typealias ShellCommandRunner = (String, [String], [String: String], TimeInterval) throws -> ShellResult

public final class NTFSMounter: VolumeMounting {
    private let ntfs3gPath: String
    private let configuration: MountConfiguration
    private let commandRunner: ShellCommandRunner
    private let formatterBundlePath: String
    private let fileManager: FileManager
    private let nativeFallbackLock = NSLock()

    public init(
        ntfs3gPath: String? = DependencyChecker.resolveNTFS3GPath(),
        configuration: MountConfiguration = MountConfiguration(),
        commandRunner: @escaping ShellCommandRunner = Shell.run,
        formatterBundlePath: String = NTFSAccessPaths.formatterBundlePath,
        fileManager: FileManager = .default
    ) throws {
        guard let ntfs3gPath else {
            throw AppError(message: "ntfs-3g executable not found")
        }

        self.ntfs3gPath = ntfs3gPath
        self.configuration = configuration
        self.commandRunner = commandRunner
        self.formatterBundlePath = formatterBundlePath
        self.fileManager = fileManager
    }

    public static func restoreDisabledFormatterBundleIfNeeded(
        formatterBundlePath: String = NTFSAccessPaths.formatterBundlePath,
        fileManager: FileManager = .default,
        commandRunner: ShellCommandRunner = Shell.run
    ) {
        let disabledPath = disabledFormatterBundlePath(for: formatterBundlePath)
        guard fileManager.fileExists(atPath: disabledPath),
              !fileManager.fileExists(atPath: formatterBundlePath) else {
            return
        }

        do {
            try fileManager.moveItem(atPath: disabledPath, toPath: formatterBundlePath)
            _ = try? commandRunner("/usr/sbin/diskutil", ["listFilesystems"], [:], 3)
        } catch {
            Log.warning("Unable to restore disabled NTFS Access filesystem bundle at startup: \(error.localizedDescription)")
        }
    }

    public func mountReadWrite(volume: DiskVolume, user: ConsoleUser) throws -> String {
        stopStaleNTFS3GWorkers(for: volume.deviceIdentifier, mountPoint: configuration.mountPoint(for: volume))
        return try mount(
            volume: volume,
            optionSets: configuration.readWriteOptionSets(for: volume, user: user)
        )
    }

    public func mountReadOnly(volume: DiskVolume, user: ConsoleUser) throws -> String {
        stopStaleNTFS3GWorkers(for: volume.deviceIdentifier, mountPoint: configuration.mountPoint(for: volume))
        return try mount(
            volume: volume,
            optionSets: configuration.readOnlyOptionSets(for: volume, user: user)
        )
    }

    public func canReadRawDevice(_ deviceNode: String) -> Bool {
        let blockPath: String
        do {
            blockPath = try DevicePathResolver.normalizedBlockDevicePath(deviceNode)
        } catch {
            Log.warning("Raw device readability check skipped for \(deviceNode): \(error.localizedDescription)")
            return false
        }

        for candidate in rawReadCandidates(for: blockPath) {
            guard let fileHandle = FileHandle(forReadingAtPath: candidate) else {
                Log.warning("Raw device readability check denied for \(candidate): open failed")
                continue
            }
            defer {
                try? fileHandle.close()
            }

            do {
                _ = try fileHandle.read(upToCount: 512)
                return true
            } catch {
                Log.warning("Raw device readability check denied for \(candidate): \(error.localizedDescription)")
            }
        }

        return false
    }

    public func unmount(deviceIdentifier: String, mountPoint: String? = nil, force: Bool = false) throws {
        let normalized = normalizeDeviceIdentifier(deviceIdentifier)
        let result = try attemptUnmount(deviceIdentifier: normalized, mountPoint: mountPoint, force: force)
        if result.status != 0 && isRetryableUnmountFailure(result.stdoutTrimmed + "\n" + result.stderrTrimmed) {
            stopStaleNTFS3GWorkers(for: normalized, mountPoint: mountPoint)
            let retry = try attemptUnmount(deviceIdentifier: normalized, mountPoint: mountPoint, force: force)
            guard retry.status == 0 else {
                let detail = retry.stderrTrimmed.isEmpty ? retry.stdoutTrimmed : retry.stderrTrimmed
                throw AppError(message: "Unmount failed for \(normalized): \(detail)")
            }
            stopStaleNTFS3GWorkers(for: normalized, mountPoint: mountPoint)
            return
        }

        guard result.status == 0 else {
            let detail = result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed
            throw AppError(message: "Unmount failed for \(normalized): \(detail)")
        }

        stopStaleNTFS3GWorkers(for: normalized, mountPoint: mountPoint)
    }

    private func attemptUnmount(deviceIdentifier normalized: String, mountPoint: String?, force: Bool) throws -> ShellResult {
        if let mountPoint, !mountPoint.isEmpty {
            var umountArguments: [String] = []
            if force {
                umountArguments.append("-f")
            }
            umountArguments.append(mountPoint)
            let result = try commandRunner("/sbin/umount", umountArguments, [:], 12)
            if result.status == 0 || isAlreadyUnmountedMessage(result.stdoutTrimmed) || isAlreadyUnmountedMessage(result.stderrTrimmed) {
                return result.status == 0
                    ? result
                    : ShellResult(status: 0, stdout: result.stdout, stderr: result.stderr)
            }
        }

        var args = ["unmount"]
        if force {
            args.append("force")
        }
        args.append("/dev/\(normalized)")
        return try commandRunner("/usr/sbin/diskutil", args, [:], 30)
    }

    public func mountNativeReadOnly(deviceIdentifier: String) throws {
        let normalized = normalizeDeviceIdentifier(deviceIdentifier)
        let result = try commandRunner("/usr/sbin/diskutil", ["mount", "readOnly", "/dev/\(normalized)"], [:], 30)

        if result.status != 0 {
            let detail = result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed
            try mountNativeReadOnlyByTemporarilyDisablingNTFSAccessBundle(
                normalizedDeviceIdentifier: normalized,
                initialFailure: detail
            )
        }
    }

    public func mountUsingRegisteredPersonality(deviceIdentifier: String, readOnly: Bool) throws {
        let normalized = normalizeDeviceIdentifier(deviceIdentifier)
        let arguments = readOnly
            ? ["mount", "readOnly", "/dev/\(normalized)"]
            : ["mount", "/dev/\(normalized)"]
        let result = try commandRunner("/usr/sbin/diskutil", arguments, [:], 45)

        guard result.status == 0 else {
            let detail = result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed
            throw AppError(message: "diskutil mount failed for \(normalized): \(detail)")
        }
    }

    public func normalizeDeviceIdentifier(_ raw: String) -> String {
        if raw.hasPrefix("/dev/") {
            return String(raw.dropFirst("/dev/".count))
        }
        return raw
    }

    private func mount(volume: DiskVolume, optionSets: [[String]]) throws -> String {
        let mountPoint = configuration.mountPoint(for: volume)
        try ensureDirectory(path: mountPoint)

        var failures: [String] = []
        for devicePath in deviceCandidates(for: volume) {
            for options in optionSets {
                let optionsValue = options.joined(separator: ",")
                Log.info("Mount attempt for \(volume.deviceIdentifier) using \(devicePath) with options: \(optionsValue)")
                let result = try commandRunner(
                    ntfs3gPath,
                    [devicePath, mountPoint, "-o", optionsValue],
                    [:],
                    90
                )

                if result.status == 0 {
                    return mountPoint
                }

                let detail = result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed
                let combinedOutput = [result.stdoutTrimmed, result.stderrTrimmed]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if isMacFUSEUnavailable(detail) {
                    throw AppError(message: "Mount failed for \(volume.deviceIdentifier): macFUSE is installed but not active. Approve it in System Settings if needed, then reboot macOS and retry.")
                }
                if isRawDiskPermissionDenied(combinedOutput) {
                    throw rawDiskPermissionDeniedError(for: volume)
                }
                failures.append("\(devicePath) [\(optionsValue)] => \(detail)")
                Log.warning("Mount attempt failed for \(volume.deviceIdentifier) using \(devicePath): \(detail)")
            }
        }

        let detail = failures.joined(separator: " | ")
        if isRawDiskPermissionDenied(detail) {
            throw rawDiskPermissionDeniedError(for: volume)
        }
        throw AppError(message: "Mount failed for \(volume.deviceIdentifier): \(detail)")
    }

    private func rawDiskPermissionDeniedError(for volume: DiskVolume) -> AppError {
        AppError(
            message: """
            Mount failed for \(volume.deviceIdentifier): macOS denied raw disk access to \(volume.deviceNode). This is a system privacy/policy denial below NTFS Access, not evidence that the NTFS volume itself is dirty. Admin/root is not enough here. Grant Full Disk Access to the currently installed /Applications/NTFS Access.app, then restart NTFS Access or run ntfsaccessctl retry-mounts --wait. Because this build is ad-hoc signed, rebuilding or reinstalling can make macOS treat it as a new app and require removing and re-adding NTFS Access.app in Full Disk Access.
            """
        )
    }

    private func ensureDirectory(path: String) throws {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw AppError(message: "Mount path exists but is not directory: \(path)")
            }
            try ensureDirectoryIsUserAccessible(path: path)
            return
        }

        try fileManager.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
    }

    private func ensureDirectoryIsUserAccessible(path: String) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if permissions & 0o055 == 0o055 {
            return
        }

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func mountNativeReadOnlyByTemporarilyDisablingNTFSAccessBundle(
        normalizedDeviceIdentifier: String,
        initialFailure: String
    ) throws {
        nativeFallbackLock.lock()
        defer { nativeFallbackLock.unlock() }

        guard fileManager.fileExists(atPath: formatterBundlePath) else {
            throw AppError(message: "Native read-only mount failed for \(normalizedDeviceIdentifier): \(initialFailure)")
        }

        let disabledPath = Self.disabledFormatterBundlePath(for: formatterBundlePath)
        if fileManager.fileExists(atPath: disabledPath) {
            throw AppError(
                message: "Native read-only recovery is already in progress or a previous recovery left \(disabledPath). Refusing to delete it; restore that path or restart NTFS Access before retrying."
            )
        }

        var bundleWasMoved = false
        do {
            try fileManager.moveItem(atPath: formatterBundlePath, toPath: disabledPath)
            bundleWasMoved = true
            refreshFilesystemPersonalitiesBestEffort()

            let retry = try commandRunner("/usr/sbin/diskutil", ["mount", "readOnly", "/dev/\(normalizedDeviceIdentifier)"], [:], 30)
            guard retry.status == 0 else {
                let detail = retry.stderrTrimmed.isEmpty ? retry.stdoutTrimmed : retry.stderrTrimmed
                throw AppError(message: "Native read-only recovery failed for \(normalizedDeviceIdentifier): \(detail). Initial mount failure: \(initialFailure)")
            }
        } catch {
            if bundleWasMoved {
                try? restoreFormatterBundle(from: disabledPath)
            }
            throw error
        }

        try restoreFormatterBundle(from: disabledPath)
    }

    private func restoreFormatterBundle(from disabledPath: String) throws {
        if fileManager.fileExists(atPath: disabledPath) && !fileManager.fileExists(atPath: formatterBundlePath) {
            try fileManager.moveItem(atPath: disabledPath, toPath: formatterBundlePath)
        }
        refreshFilesystemPersonalitiesBestEffort()
    }

    private static func disabledFormatterBundlePath(for formatterBundlePath: String) -> String {
        "\(formatterBundlePath).disabled-for-native-recovery"
    }

    private func refreshFilesystemPersonalitiesBestEffort() {
        _ = try? commandRunner("/usr/sbin/diskutil", ["listFilesystems"], [:], 3)
    }

    private func deviceCandidates(for volume: DiskVolume) -> [String] {
        let blockPath = volume.deviceNode
        let rawPath = DevicePathResolver.preferredRawDevicePath(for: blockPath)
        if rawPath != blockPath {
            return [blockPath, rawPath]
        }
        return [blockPath]
    }

    private func rawReadCandidates(for blockPath: String) -> [String] {
        let rawPath = DevicePathResolver.preferredRawDevicePath(for: blockPath)
        if rawPath == blockPath {
            return [blockPath]
        }
        return [blockPath, rawPath]
    }

    private func isMacFUSEUnavailable(_ detail: String) -> Bool {
        detail.localizedCaseInsensitiveContains("mount_macfuse: the file system is not available")
    }

    private func isRawDiskPermissionDenied(_ detail: String) -> Bool {
        let lowercased = detail.lowercased()
        let mentionsDeviceNode = lowercased.contains("/dev/disk") || lowercased.contains("/dev/rdisk")
        let denied = lowercased.contains("operation not permitted") || lowercased.contains("permission denied")
        return mentionsDeviceNode && denied
    }

    private func isAlreadyUnmountedMessage(_ detail: String) -> Bool {
        let lowercased = detail.lowercased()
        return lowercased.contains("not currently mounted")
            || lowercased.contains("not mounted")
            || lowercased.contains("not a mounted file system")
            || lowercased.contains("not a mounted filesystem")
    }

    private func isRetryableUnmountFailure(_ detail: String) -> Bool {
        let lowercased = detail.lowercased()
        return lowercased.contains("busy")
            || lowercased.contains("resource")
            || lowercased.contains("timed out")
            || lowercased.contains("timeout")
            || lowercased.contains("not responding")
    }

    private func stopStaleNTFS3GWorkers(for deviceIdentifier: String, mountPoint: String? = nil) {
        let normalized = normalizeDeviceIdentifier(deviceIdentifier)
        let devicePattern = "ntfs-3g .*/dev/(r?\(normalized))( |$)"
        let pattern: String
        if let mountPoint, !mountPoint.isEmpty {
            pattern = "\(devicePattern).*\(escapedRegexLiteral(mountPoint))( |$)"
        } else {
            pattern = devicePattern
        }
        guard let result = try? commandRunner("/usr/bin/pgrep", ["-f", pattern], [:], 10) else {
            return
        }
        let pids = result.stdout
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { Int32($0) != nil }

        guard !pids.isEmpty else {
            return
        }

        _ = try? commandRunner("/bin/kill", ["-TERM"] + pids, [:], 10)
        Thread.sleep(forTimeInterval: 0.5)

        let survivingPIDs = pids.filter { pid in
            guard let result = try? commandRunner("/bin/kill", ["-0", pid], [:], 2) else {
                return false
            }
            return result.status == 0
        }

        if !survivingPIDs.isEmpty {
            _ = try? commandRunner("/bin/kill", ["-KILL"] + survivingPIDs, [:], 10)
        }
    }

    private func escapedRegexLiteral(_ raw: String) -> String {
        var escaped = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case ".", "\\", "+", "*", "?", "[", "^", "]", "$", "(", ")", "{", "}", "=", "!", "<", ">", "|", ":", "-", "#":
                escaped.append("\\")
                escaped.append(String(scalar))
            default:
                escaped.append(String(scalar))
            }
        }
        return escaped
    }
}
