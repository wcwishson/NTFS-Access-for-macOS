import Darwin
import Foundation
import NTFSAccessCore
import NTFSAccessShared

@main
struct NTFSAccessCtlMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"

        do {
            switch command {
            case "help", "--help", "-h":
                printHelp()
            case "doctor":
                runDoctor()
            case "status":
                try runStatus()
            case "list-volumes":
                try runListVolumes(arguments: Array(args.dropFirst()))
            case "list-filesystems":
                try runListFilesystems()
            case "preflight-live":
                try runPreflightLive()
            case "stage-live-job":
                try runStageLiveJob(arguments: Array(args.dropFirst()))
            case "live-job-status":
                try runLiveJobStatus()
            case "notifications":
                try runNotifications(arguments: Array(args.dropFirst()))
            case "durability":
                try runDurability(arguments: Array(args.dropFirst()))
            case "scan-now":
                try runScanNow(arguments: Array(args.dropFirst()))
            case "retry-mounts":
                try runRetryMounts(arguments: Array(args.dropFirst()))
            case "repair-volume":
                try runRepairVolume(arguments: Array(args.dropFirst()))
            case "eject-volume":
                try runEjectVolume(arguments: Array(args.dropFirst()))
            case "partition-ntfs":
                try runPartitionNTFS(arguments: Array(args.dropFirst()))
            case "tail-log":
                try runTailLog(arguments: Array(args.dropFirst()))
            default:
                throw AppError(message: "Unknown command: \(command)")
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runDoctor() {
        let report = DependencyChecker.run(requireRoot: false)
        print("System: \(report.operatingSystem)")
        print("Architecture: \(report.architecture)")
        print("Formatter personality: \(report.ntfsFormatterPersonalityName)")
        print("ntfs-3g: \(report.ntfs3gPath ?? "not found")")
        print("ntfs-3g.probe: \(report.ntfs3gProbePath ?? "not found")")
        print("mkntfs: \(report.mkntfsPath ?? "not found")")
        print("ntfsfix: \(report.ntfsfixPath ?? "not found")")
        print("ntfslabel: \(report.ntfslabelPath ?? "not found")")
        print("macFUSE helper: \(report.macFUSEHelperPath ?? "not found")")
        print("Formatter bundle path: \(report.formatterBundlePath ?? "not found")")
        print("Formatter bundle installed: \(report.formatterBundleInstalled)")
        print("Formatter personality registered: \(report.formatterPersonalityRegistered)")
        print("Installed app signature: \(report.installedAppSignatureDescription)")
        print("Running mount daemon: \(report.runningMountDaemonProgram ?? "not running")")
        print("Running mount daemon signature: \(report.runningMountDaemonSignatureDescription)")
        print("Filesystem mount wrapper uses app helper: \(report.installedMountWrapperUsesAppHelper)")
        if !report.formatterProbeOrders.isEmpty {
            let formattedOrders = report.formatterProbeOrders
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            print("Formatter probe orders: \(formattedOrders)")
        }
        if !report.detectedNTFSPersonalities.isEmpty {
            print("Detected NTFS personalities: \(report.detectedNTFSPersonalities.joined(separator: ", "))")
        }

        print("Mount readiness: \(report.mountReady ? "ready" : "blocked")")
        for issue in report.mountIssues {
            print("- [mount] \(issue)")
        }

        print("Format readiness: \(report.formatReady ? "ready" : "blocked")")
        for issue in report.formatIssues {
            print("- [format] \(issue)")
        }

        for note in report.advisoryNotes {
            print("- [note] \(note)")
        }
    }

    private static func runStatus() throws {
        let state = try XPCClient().getServiceStateSync()
        print("health=\(state.healthRawValue)")
        print("managedVolumeCount=\(state.managedVolumeCount)")
        print("degradedVolumeCount=\(state.degradedVolumeCount)")
        print("notificationsEnabled=\(state.notificationsEnabled)")
        print("durabilityMode=\(state.durabilityModeRawValue)")
        if state.warningCount > 0 {
            print("warningCount=\(state.warningCount)")
            print("lastWarning=\(state.lastWarning)")
        }
        if !state.lastError.isEmpty {
            print("lastError=\(state.lastError)")
        }
    }

    private static func runListVolumes(arguments: [String]) throws {
        for argument in arguments where argument != "--verbose" {
            throw AppError(message: "Unknown list-volumes option: \(argument)")
        }

        let verbose = arguments.contains("--verbose")
        let states = try XPCClient().getVolumeStatesSync()
        if states.isEmpty {
            print("No managed NTFS volumes")
            return
        }

        print(verbose
            ? "DEVICE\tMODE\tMOUNTPOINT\tNAME\tPARENT_WHOLE_DISK\tPARENT_WHOLE_DISK_NAME\tREASON"
            : "DEVICE\tMODE\tMOUNTPOINT\tNAME\tREASON"
        )
        for state in states {
            let reason = state.reason.replacingOccurrences(of: "\n", with: " ")
            if verbose {
                print("\(state.deviceIdentifier)\t\(state.modeRawValue)\t\(state.mountPoint)\t\(state.volumeName)\t\(state.parentWholeDisk)\t\(state.parentWholeDiskName)\t\(reason)")
            } else {
                print("\(state.deviceIdentifier)\t\(state.modeRawValue)\t\(state.mountPoint)\t\(state.volumeName)\t\(reason)")
            }
        }
    }

    private static func runScanNow(arguments: [String]) throws {
        let wait = arguments.contains("--wait") || arguments.contains("--blocking")
        let result = try wait
            ? XPCClient().scanNowBlockingSync()
            : XPCClient().scanNowSync()
        print(result.message)
    }

    private static func runRetryMounts(arguments: [String]) throws {
        for argument in arguments where argument != "--wait" && argument != "--blocking" {
            throw AppError(message: "Unknown retry-mounts option: \(argument)")
        }

        let wait = arguments.contains("--wait") || arguments.contains("--blocking")
        let client = XPCClient()
        let result = try wait ? client.retryMountsBlockingSync() : client.retryMountsSync()
        print(result.message)
    }

    private static func runRepairVolume(arguments: [String]) throws {
        var stableIdentity: String?
        var action = VolumeRecoveryActionRaw.retryMount
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--stable-identity", "--device":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after \(arguments[index])")
                }
                stableIdentity = arguments[index + 1]
                index += 2
            case "--action":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --action")
                }
                guard let parsed = VolumeRecoveryActionRaw(rawValue: arguments[index + 1]) else {
                    throw AppError(message: "Unknown repair action: \(arguments[index + 1])")
                }
                action = parsed
                index += 2
            default:
                throw AppError(message: "Unknown repair-volume option: \(arguments[index])")
            }
        }

        guard let stableIdentity, !stableIdentity.isEmpty else {
            throw AppError(message: "repair-volume requires --stable-identity <id> or --device <diskXsY>")
        }

        let result = try XPCClient().repairVolumeSync(stableIdentity: stableIdentity, action: action)
        print(result.message)
    }

    private static func runEjectVolume(arguments: [String]) throws {
        var stableIdentity: String?
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--stable-identity", "--device":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after \(arguments[index])")
                }
                stableIdentity = arguments[index + 1]
                index += 2
            default:
                throw AppError(message: "Unknown eject-volume option: \(arguments[index])")
            }
        }

        guard let stableIdentity, !stableIdentity.isEmpty else {
            throw AppError(message: "eject-volume requires --stable-identity <id> or --device <diskXsY>")
        }

        let result = try XPCClient().ejectVolumeSync(stableIdentity: stableIdentity)
        print(result.message)
    }

    private static func runNotifications(arguments: [String]) throws {
        let subcommand = arguments.first ?? "status"
        let client = XPCClient()

        switch subcommand {
        case "status":
            let state = try client.getServiceStateSync()
            print("notificationsEnabled=\(state.notificationsEnabled)")
        case "on":
            let result = try client.setNotificationsEnabledSync(true)
            print(result.message)
        case "off":
            let result = try client.setNotificationsEnabledSync(false)
            print(result.message)
        default:
            throw AppError(message: "Unknown notifications command: \(subcommand)")
        }
    }

    private static func runDurability(arguments: [String]) throws {
        let subcommand = arguments.first ?? "status"
        let client = XPCClient()

        switch subcommand {
        case "status":
            let state = try client.getServiceStateSync()
            print("durabilityMode=\(state.durabilityModeRawValue)")
            if state.warningCount > 0 {
                print("warningCount=\(state.warningCount)")
                print("lastWarning=\(state.lastWarning)")
            }
        case "performance":
            let result = try client.setDurabilityModeSync(.performance)
            print(result.message)
        case "conservative":
            let result = try client.setDurabilityModeSync(.conservative)
            print(result.message)
        default:
            throw AppError(message: "Unknown durability command: \(subcommand)")
        }
    }

    private static func runListFilesystems() throws {
        let output = try FileSystemPersonalityInspector.listFormattableFileSystems()
        print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
    }

    private static func runPreflightLive() throws {
        let report = DependencyChecker.run(requireRoot: false)
        let stagedRoot = "/Users/Shared/NTFSAccessLiveBatch"
        let stagedRunner = "\(stagedRoot)/scripts/run_live_multi_device_admin_batch.sh"
        let stagedUserRunner = "\(stagedRoot)/scripts/run_live_user_validation_batch.sh"
        let requestRoot = "\(stagedRoot)/requests"
        let installedRunner = "\(NTFSAccessPaths.supportDirectoryPath)/live_job_runner.sh"
        let liveJobLaunchDaemon = "/Library/LaunchDaemons/com.ntfsaccess.livejob.plist"
        let stagedConfig = "\(requestRoot)/live-job.conf"
        let triggerPath = "\(requestRoot)/live-job.trigger"

        print("Live NTFS preflight:")
        print("Mount readiness: \(report.mountReady ? "ready" : "blocked")")
        print("Format readiness: \(report.formatReady ? "ready" : "blocked")")
        print("Installed app signature: \(report.installedAppSignatureDescription)")
        print("Running mount daemon: \(report.runningMountDaemonProgram ?? "not running")")
        print("Running mount daemon signature: \(report.runningMountDaemonSignatureDescription)")
        print("Filesystem mount wrapper uses app helper: \(report.installedMountWrapperUsesAppHelper)")
        print("Installed root runner: \(FileManager.default.isExecutableFile(atPath: installedRunner) ? "ready" : "missing")")
        print("Installed no-password live-job daemon: \(FileManager.default.fileExists(atPath: liveJobLaunchDaemon) ? "ready" : "missing")")
        print("Shared staged runner: \(FileManager.default.isExecutableFile(atPath: stagedRunner) ? "ready" : "missing")")
        print("Shared user-session validator: \(FileManager.default.isExecutableFile(atPath: stagedUserRunner) ? "ready" : "missing")")
        print("Shared staged config: \(FileManager.default.fileExists(atPath: stagedConfig) ? "ready" : "missing")")
        print("Shared live-job trigger: \(FileManager.default.fileExists(atPath: triggerPath) ? "ready" : "missing")")

        for issue in report.mountIssues {
            print("- [mount] \(issue)")
        }
        for issue in report.formatIssues {
            print("- [format] \(issue)")
        }
        for note in report.advisoryNotes {
            print("- [note] \(note)")
        }

        try printExternalNTFSPreflight()
    }

    private static func runStageLiveJob(arguments: [String]) throws {
        var remountCycles = "12"
        var soakCycles = "40"
        var multiCycles = "12"
        var largeFileMiB = "64"
        var randomFileCount = "4"
        var randomFileMiB = "16"
        var multiSourceMiB = "32"
        var skipInstall = true
        var startAfterStage = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--remount-cycles":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --remount-cycles")
                }
                remountCycles = try validatedPositiveInteger(arguments[index + 1], optionName: "--remount-cycles")
                index += 2
            case "--soak-cycles":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --soak-cycles")
                }
                soakCycles = try validatedPositiveInteger(arguments[index + 1], optionName: "--soak-cycles")
                index += 2
            case "--multi-cycles":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --multi-cycles")
                }
                multiCycles = try validatedPositiveInteger(arguments[index + 1], optionName: "--multi-cycles")
                index += 2
            case "--large-file-mib":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --large-file-mib")
                }
                largeFileMiB = try validatedPositiveInteger(arguments[index + 1], optionName: "--large-file-mib")
                index += 2
            case "--random-file-count":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --random-file-count")
                }
                randomFileCount = try validatedPositiveInteger(arguments[index + 1], optionName: "--random-file-count")
                index += 2
            case "--random-file-mib":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --random-file-mib")
                }
                randomFileMiB = try validatedPositiveInteger(arguments[index + 1], optionName: "--random-file-mib")
                index += 2
            case "--multi-source-mib":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --multi-source-mib")
                }
                multiSourceMiB = try validatedPositiveInteger(arguments[index + 1], optionName: "--multi-source-mib")
                index += 2
            case "--install":
                skipInstall = false
                index += 1
            case "--skip-install":
                skipInstall = true
                index += 1
            case "--start":
                startAfterStage = true
                index += 1
            default:
                throw AppError(message: "Unknown stage-live-job option: \(argument)")
            }
        }

        let stagedRoot = URL(fileURLWithPath: "/Users/Shared/NTFSAccessLiveBatch", isDirectory: true)
        let requestRoot = stagedRoot.appendingPathComponent("requests", isDirectory: true)
        let logsRoot = stagedRoot.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: requestRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        try setSharedDirectoryPermissionsIfOwned(path: stagedRoot.path, permissions: 0o755)
        try setSharedDirectoryPermissionsIfOwned(path: requestRoot.path, permissions: 0o1777)

        let config = [
            "# NTFS Access live-test job config",
            "# Plain KEY=VALUE only. The installed root runner ignores everything except this allow-list.",
            "SKIP_INSTALL=\(skipInstall ? "1" : "0")",
            "NTFSACCESS_REMOUNT_CYCLES=\(remountCycles)",
            "NTFSACCESS_SOAK_CYCLES=\(soakCycles)",
            "NTFSACCESS_MULTI_CYCLES=\(multiCycles)",
            "NTFSACCESS_LARGE_FILE_MIB=\(largeFileMiB)",
            "NTFSACCESS_RANDOM_FILE_COUNT=\(randomFileCount)",
            "NTFSACCESS_RANDOM_FILE_MIB=\(randomFileMiB)",
            "NTFSACCESS_MULTI_SOURCE_MIB=\(multiSourceMiB)",
            ""
        ].joined(separator: "\n")

        let configURL = requestRoot.appendingPathComponent("live-job.conf")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        _ = try? Shell.run("/bin/chmod", ["644", configURL.path], timeout: 5)

        print("Staged live job config: \(configURL.path)")
        print("skipInstall=\(skipInstall)")
        print("remountCycles=\(remountCycles)")
        print("soakCycles=\(soakCycles)")
        print("multiCycles=\(multiCycles)")
        print("largeFileMiB=\(largeFileMiB)")
        print("randomFileCount=\(randomFileCount)")
        print("randomFileMiB=\(randomFileMiB)")
        print("multiSourceMiB=\(multiSourceMiB)")
        if startAfterStage {
            try triggerLiveJob()
        } else {
            print("Start without another password if the live-job daemon is installed:")
            print("  ntfsaccessctl stage-live-job --skip-install --start")
            print("Fallback one-time admin run:")
            print("  /bin/bash '\(NTFSAccessPaths.supportDirectoryPath)/live_job_runner.sh'")
        }
    }

    private static func runLiveJobStatus() throws {
        let logRoot = URL(fileURLWithPath: "/Users/Shared/NTFSAccessLiveBatch/logs", isDirectory: true)
        let latestLog = logRoot.appendingPathComponent("latest.log")
        let config = URL(fileURLWithPath: "/Users/Shared/NTFSAccessLiveBatch/requests/live-job.conf")

        print("Live job config: \(FileManager.default.fileExists(atPath: config.path) ? config.path : "missing")")
        print("Latest live job log: \(FileManager.default.fileExists(atPath: latestLog.path) ? latestLog.path : "missing")")
        print("No-password live-job daemon: \(FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.ntfsaccess.livejob.plist") ? "installed" : "missing")")

        guard FileManager.default.fileExists(atPath: latestLog.path) else {
            return
        }

        let result = try Shell.run("/usr/bin/tail", ["-40", latestLog.path], timeout: 8)
        print(result.stdout, terminator: result.stdout.hasSuffix("\n") ? "" : "\n")
        if !result.stderrTrimmed.isEmpty {
            fputs(result.stderrTrimmed + "\n", stderr)
        }
    }

    private static func runPartitionNTFS(arguments: [String]) throws {
        var wholeDisk: String?
        var names: [String] = []
        var confirmed = false
        var typedConfirmation: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--disk":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --disk")
                }
                wholeDisk = arguments[index + 1]
                index += 2
            case "--names":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --names")
                }
                names = arguments[index + 1]
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                index += 2
            case "--yes-destroy":
                confirmed = true
                index += 1
            case "--confirm":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing value after --confirm")
                }
                typedConfirmation = arguments[index + 1]
                index += 2
            default:
                throw AppError(message: "Unknown partition-ntfs option: \(argument)")
            }
        }

        guard let wholeDisk else {
            throw AppError(message: "Missing --disk /dev/diskX")
        }
        guard confirmed else {
            throw AppError(message: "Refusing to partition without --yes-destroy. This erases the whole disk.")
        }

        let request = try NTFSPartitionRequest(wholeDisk: wholeDisk, volumeNames: names)
        let partitioner = NTFSPartitioner()
        let summary = try partitioner.dryRunSummary(request: request)
        for line in summary.humanReadableLines {
            print(line)
        }
        guard let typedConfirmation else {
            throw AppError(message: "Refusing to partition without --confirm \"\(summary.confirmationPhrase)\".")
        }

        let result = try partitioner.partition(request: request, confirmation: typedConfirmation)
        if !result.stdoutTrimmed.isEmpty {
            print(result.stdoutTrimmed)
        }
        if !result.stderrTrimmed.isEmpty {
            fputs(result.stderrTrimmed + "\n", stderr)
        }
    }

    private static func runTailLog(arguments: [String]) throws {
        let lines = arguments.first.flatMap(Int.init) ?? 200
        let windows: [(String, TimeInterval)] = [
            ("15m", 12),
            ("5m", 8),
            ("1m", 6)
        ]

        var lastError: Error?
        for (window, timeout) in windows {
            do {
                let result = try Shell.runChecked(
                    "/usr/bin/log",
                    [
                        "show",
                        "--style", "compact",
                        "--predicate", "subsystem == 'com.ntfsaccess'",
                        "--last", window
                    ],
                    timeout: timeout
                )

                let outputLines = result.stdout.split(separator: "\n")
                let tail = outputLines.suffix(lines)
                for line in tail {
                    print(String(line))
                }
                if tail.isEmpty {
                    print("No recent NTFS Access log entries found in the last \(window).")
                }
                return
            } catch {
                lastError = error
                if !error.localizedDescription.localizedCaseInsensitiveContains("timed out") {
                    throw error
                }
            }
        }

        if let lastError {
            throw lastError
        }
    }

    private static func printExternalNTFSPreflight() throws {
        let result = try Shell.run("/usr/sbin/diskutil", ["list", "external", "physical"], timeout: 12)
        guard result.status == 0 else {
            print("External disk scan: unavailable")
            if !result.stderrTrimmed.isEmpty {
                print("- [diskutil] \(result.stderrTrimmed)")
            }
            return
        }

        var candidates: [String] = []
        for line in result.stdout.split(separator: "\n") {
            let text = String(line)
            if text.contains("Windows_NTFS") || text.contains("Microsoft Basic Data") {
                if let last = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).last {
                    candidates.append("/dev/\(last)")
                }
            }
        }

        if candidates.isEmpty {
            print("Live NTFS targets: none found")
            return
        }

        print("Live NTFS candidates:")
        for device in candidates {
            print("- \(device)")
        }
    }

    private static func triggerLiveJob() throws {
        let stagedRoot = URL(fileURLWithPath: "/Users/Shared/NTFSAccessLiveBatch", isDirectory: true)
        let requestRoot = stagedRoot.appendingPathComponent("requests", isDirectory: true)
        let triggerURL = requestRoot.appendingPathComponent("live-job.trigger")
        let launchDaemon = "/Library/LaunchDaemons/com.ntfsaccess.livejob.plist"
        let stamp = ISO8601DateFormatter().string(from: Date())

        guard FileManager.default.fileExists(atPath: launchDaemon) else {
            throw AppError(
                message: """
                The no-password live-job daemon is not installed yet. Install the package once, or use the fallback one-time admin runner:
                  /bin/bash '\(NTFSAccessPaths.supportDirectoryPath)/live_job_runner.sh'
                """
            )
        }

        try FileManager.default.createDirectory(at: requestRoot, withIntermediateDirectories: true)
        try setSharedDirectoryPermissionsIfOwned(path: stagedRoot.path, permissions: 0o755)
        try setSharedDirectoryPermissionsIfOwned(path: requestRoot.path, permissions: 0o1777)
        try "requestedAt=\(stamp)\n".write(to: triggerURL, atomically: true, encoding: .utf8)
        _ = try? Shell.run("/bin/chmod", ["644", triggerURL.path], timeout: 5)
        print("Triggered no-password live job through launchd.")
        print("Watch progress with:")
        print("  ntfsaccessctl live-job-status")
    }

    private static func setSharedDirectoryPermissionsIfOwned(path: String, permissions: Int) throws {
        if geteuid() == 0 {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
            return
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == geteuid() else {
            return
        }

        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }

    private static func validatedPositiveInteger(_ value: String, optionName: String) throws -> String {
        guard Int(value).map({ $0 > 0 }) == true else {
            throw AppError(message: "\(optionName) must be a positive whole number")
        }
        return value
    }

    private static func printHelp() {
        print(
            """
            ntfsaccessctl commands:
              doctor
              status
              list-volumes
              list-filesystems
              preflight-live
              stage-live-job [--skip-install|--install] [--remount-cycles N] [--soak-cycles N] [--multi-cycles N] [--large-file-mib N] [--random-file-count N] [--random-file-mib N] [--multi-source-mib N] [--start]
              live-job-status
              run user validation: /Users/Shared/NTFSAccessLiveBatch/scripts/run_live_user_validation_batch.sh
              notifications [status|on|off]
  durability [status|performance|conservative]
  scan-now
  retry-mounts [--wait]
  repair-volume --stable-identity <id>|--device <diskXsY> [--action retryMount|retryWritableTakeover|rescan]
  eject-volume --stable-identity <id>|--device <diskXsY>
  partition-ntfs --disk /dev/diskX --names NameA,NameB[,NameC] --yes-destroy --confirm "ERASE diskX"
  tail-log [N]
"""
        )
    }
}
