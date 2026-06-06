import Foundation
import Darwin

public enum DependencyChecker {
    static let unsafeToolchainLookupFlag = "NTFSACCESS_ALLOW_UNSAFE_TOOLCHAIN_LOOKUP"
    private static let ntfsToolNamesRequiringLibrary: Set<String> = [
        "ntfs-3g",
        "ntfs-3g.probe",
        "mkntfs",
        "ntfsfix",
        "ntfslabel"
    ]

    struct BinaryResolution {
        let path: String?
        let rejectionMessages: [String]
    }

    public static func run(requireRoot: Bool = false) -> DependencyReport {
        run(requireRoot: requireRoot, macFUSEKernelLoaded: nil)
    }

    public static func run(requireRoot: Bool, macFUSEKernelLoaded: (() -> Bool?)?) -> DependencyReport {
        return run(
            requireRoot: requireRoot,
            macFUSEKernelLoaded: macFUSEKernelLoaded,
            architectureProvider: currentMachineArchitecture
        )
    }

    public static func run(
        requireRoot: Bool,
        macFUSEKernelLoaded: (() -> Bool?)?,
        architectureProvider: () -> String
    ) -> DependencyReport {
        let privilegedRuntime = requireRoot || geteuid() == 0
        return run(
            requireRoot: requireRoot,
            macFUSEKernelLoaded: macFUSEKernelLoaded,
            architectureProvider: architectureProvider,
            toolResolver: { binary, includePATHLookup, fallbackDirectories in
                DependencyChecker.resolveBinary(
                    named: binary,
                    includePATHLookup: includePATHLookup,
                    fallbackDirectories: fallbackDirectories,
                    privilegedRuntime: privilegedRuntime
                )
            },
            toolDiagnosticsResolver: { binary, includePATHLookup, fallbackDirectories in
                DependencyChecker.resolveBinaryDetailed(
                    named: binary,
                    includePATHLookup: includePATHLookup,
                    fallbackDirectories: fallbackDirectories,
                    environment: ProcessInfo.processInfo.environment,
                    privilegedRuntime: privilegedRuntime
                ).rejectionMessages
            }
        )
    }

    static func run(
        requireRoot: Bool,
        macFUSEKernelLoaded: (() -> Bool?)?,
        architectureProvider: () -> String,
        toolResolver: (String, Bool, [String]) -> String?,
        toolDiagnosticsResolver: (String, Bool, [String]) -> [String] = { _, _, _ in [] },
        formatterBundleInstalledProvider: () -> Bool = {
            FileManager.default.fileExists(atPath: NTFSAccessPaths.formatterInfoPlistPath)
        },
        formatterPersonalityRegisteredProvider: () -> Bool = {
            FileSystemPersonalityInspector.formatterPersonalityRegistered()
        },
        formatterProbeOrdersProvider: () -> [String: Int] = {
            FileSystemPersonalityInspector.formatterProbeOrders()
        },
        detectedNTFSPersonalitiesProvider: () -> [String] = {
            FileSystemPersonalityInspector.detectedNTFSPersonalities()
        },
        installedAppSignatureProvider: () -> String = installedAppSignatureDescription,
        runningMountDaemonProgramProvider: () -> String? = runningMountDaemonProgramPath,
        installedMountWrapperUsesAppHelperProvider: () -> Bool = installedMountWrapperUsesAppHelper
    ) -> DependencyReport {
        var mountIssues: [String] = []
        var formatIssues: [String] = []
        var advisoryNotes: [String] = []
        var toolRejectionDiagnostics = Set<String>()

        func resolveTool(_ binary: String, includePATHLookup: Bool, fallbackDirectories: [String]) -> String? {
            for diagnostic in toolDiagnosticsResolver(binary, includePATHLookup, fallbackDirectories) {
                toolRejectionDiagnostics.insert(diagnostic)
            }
            return toolResolver(binary, includePATHLookup, fallbackDirectories)
        }

        let architecture = resolvedArchitecture(architectureProvider())
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString

        let ntfs3g = resolveTool("ntfs-3g", includePATHLookup: true, fallbackDirectories: [])
        let ntfs3gProbe = resolveTool("ntfs-3g.probe", includePATHLookup: true, fallbackDirectories: [])
        let mkntfs = resolveTool("mkntfs", includePATHLookup: true, fallbackDirectories: [])
        let ntfsfix = resolveTool("ntfsfix", includePATHLookup: true, fallbackDirectories: [])
        let ntfslabel = resolveTool("ntfslabel", includePATHLookup: true, fallbackDirectories: [])
        let macfuse = resolveTool(
            "mount_macfuse",
            includePATHLookup: false,
            fallbackDirectories: [
                "/Library/Filesystems/macfuse.fs/Contents/Resources",
                "/opt/homebrew/bin",
                "/usr/local/bin"
            ]
        )
        let formatterBundleInstalled = formatterBundleInstalledProvider()
        let formatterRegistered = formatterPersonalityRegisteredProvider()
        let formatterProbeOrders = formatterProbeOrdersProvider()
        let ntfsPersonalities = detectedNTFSPersonalitiesProvider()
        let appSignature = installedAppSignatureProvider()
        let runningMountDaemonProgram = runningMountDaemonProgramProvider()
        let runningMountDaemonSignature = signatureDescription(forPath: runningMountDaemonProgram)
        let mountWrapperUsesAppHelper = installedMountWrapperUsesAppHelperProvider()

        if ntfs3g == nil {
            mountIssues.append("Missing ntfs-3g (install the managed toolchain with: ./scripts/bootstrap_ntfs_toolchain.sh --install-build-deps, then sudo ./scripts/bootstrap_ntfs_toolchain.sh)")
            advisoryNotes.append("Current Homebrew ntfs-3g packaging is Linux-only on this macOS host; use the repo bootstrap script to install the managed NTFS toolchain.")
        }

        if ntfs3g != nil && ntfs3gProbe == nil {
            advisoryNotes.append("ntfs-3g.probe not found; NTFS Access will refuse writable mounts that cannot be safety-checked and will use read-only fallback instead.")
        }

        if macfuse == nil {
            mountIssues.append("Missing macFUSE mount helper (install: brew install --cask macfuse or use https://macfuse.github.io)")
        } else {
            switch macFUSEKernelLoaded?() ?? detectMacFUSEKernelLoaded() {
            case .some(true):
                break
            case .some(false):
                advisoryNotes.append("macFUSE kernel extension not loaded yet; the first real NTFS mount may ask macOS to approve macFUSE in System Settings -> Privacy & Security and then reboot")
            case .none:
                advisoryNotes.append("Unable to determine if macFUSE kernel extension is loaded; ensure it is approved in System Settings if required")
            }
        }

        if mkntfs == nil {
            formatIssues.append("Missing mkntfs formatter backend")
        }

        if ntfsfix == nil {
            formatIssues.append("Missing ntfsfix verification/repair backend")
        }

        if ntfslabel == nil {
            advisoryNotes.append("ntfslabel not found; formatter will create unlabeled volumes if Disk Utility does not provide a label through mkntfs")
        }

        for diagnostic in toolRejectionDiagnostics.sorted() {
            advisoryNotes.append(diagnostic)
        }

        if !formatterBundleInstalled {
            formatIssues.append("NTFS Access filesystem bundle is not installed at \(NTFSAccessPaths.formatterBundlePath)")
        }

        if formatterBundleInstalled && !formatterRegistered {
            formatIssues.append("NTFS Access formatter personality is not visible in diskutil/Disk Utility")
        }

        if let windowsNTFSProbeOrder = formatterProbeOrders["Windows_NTFS"], windowsNTFSProbeOrder > 1_000 {
            mountIssues.append("NTFS Access filesystem bundle probes after Apple's native NTFS handler; Finder automounts will stay read-only until the app bundle is reinstalled")
        }

        if requireRoot && geteuid() != 0 {
            mountIssues.append("Root privileges required for mount operations")
        }

        if architecture != "arm64" {
            mountIssues.append("Apple Silicon is the supported target for this build; detected architecture: \(architecture)")
        }

        let thirdPartyPersonalities = ntfsPersonalities.filter { !$0.localizedCaseInsensitiveContains(NTFSAccessPaths.formatterPersonalityName) }
        if !thirdPartyPersonalities.isEmpty {
            advisoryNotes.append("Detected other NTFS formatter personalities: \(thirdPartyPersonalities.joined(separator: ", ")). Disk Utility may surface only one NTFS formatter in the GUI when multiple personalities are installed.")
        }

        if appSignature.localizedCaseInsensitiveContains("adhoc") {
            advisoryNotes.append("Installed NTFS Access.app is ad-hoc signed. macOS may treat each rebuilt installer as a new privacy identity, so Full Disk Access can require removing and re-adding /Applications/NTFS Access.app after reinstalling.")
        } else if appSignature.localizedCaseInsensitiveContains("NTFS Access Local Signing") {
            advisoryNotes.append("Installed NTFS Access.app uses the stable local signing identity. Full Disk Access should survive rebuilds after one fresh approval of this identity.")
        }

        if formatterBundleInstalled && !mountWrapperUsesAppHelper {
            mountIssues.append("Filesystem mount wrapper is not delegating through /Applications/NTFS Access.app; raw-disk privacy approval may attach to a hidden helper instead of the app you can approve in System Settings")
        }

        return DependencyReport(
            operatingSystem: operatingSystem,
            architecture: architecture,
            ntfs3gPath: ntfs3g,
            ntfs3gProbePath: ntfs3gProbe,
            mkntfsPath: mkntfs,
            ntfsfixPath: ntfsfix,
            ntfslabelPath: ntfslabel,
            macFUSEHelperPath: macfuse,
            formatterBundlePath: NTFSAccessPaths.formatterBundlePath,
            formatterBundleInstalled: formatterBundleInstalled,
            formatterPersonalityRegistered: formatterRegistered,
            formatterProbeOrders: formatterProbeOrders,
            ntfsFormatterPersonalityName: NTFSAccessPaths.formatterPersonalityName,
            detectedNTFSPersonalities: ntfsPersonalities,
            installedAppSignatureDescription: appSignature,
            runningMountDaemonProgram: runningMountDaemonProgram,
            runningMountDaemonSignatureDescription: runningMountDaemonSignature,
            installedMountWrapperUsesAppHelper: mountWrapperUsesAppHelper,
            mountIssues: mountIssues,
            formatIssues: formatIssues,
            advisoryNotes: advisoryNotes
        )
    }

    static func currentMachineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }

        return normalizedArchitecture(machine)
    }

    public static func resolveNTFS3GPath() -> String? {
        resolveBinary(
            named: "ntfs-3g",
            fallbackDirectories: []
        )
    }

    public static func resolveNTFS3GProbePath() -> String? {
        resolveBinary(
            named: "ntfs-3g.probe",
            fallbackDirectories: []
        )
    }

    public static func resolveMKNTFSPath() -> String? {
        resolveBinary(
            named: "mkntfs",
            fallbackDirectories: []
        )
    }

    public static func resolveNTFSFixPath() -> String? {
        resolveBinary(
            named: "ntfsfix",
            fallbackDirectories: []
        )
    }

    public static func resolveNTFSLabelPath() -> String? {
        resolveBinary(
            named: "ntfslabel",
            fallbackDirectories: []
        )
    }

    public static func resolveMacFUSEHelperPath() -> String? {
        resolveBinary(
            named: "mount_macfuse",
            includePATHLookup: false,
            fallbackDirectories: [
                "/Library/Filesystems/macfuse.fs/Contents/Resources",
                "/opt/homebrew/bin",
                "/usr/local/bin"
            ]
        )
    }

    private static func resolveBinary(
        named binary: String,
        includePATHLookup: Bool = true,
        fallbackDirectories: [String],
        privilegedRuntime: Bool = geteuid() == 0
    ) -> String? {
        resolveBinaryDetailed(
            named: binary,
            includePATHLookup: includePATHLookup,
            fallbackDirectories: fallbackDirectories,
            environment: ProcessInfo.processInfo.environment,
            privilegedRuntime: privilegedRuntime
        ).path
    }

    static func resolveBinaryDetailed(
        named binary: String,
        includePATHLookup: Bool = true,
        fallbackDirectories: [String],
        environment: [String: String],
        privilegedRuntime: Bool
    ) -> BinaryResolution {
        let fileManager = FileManager.default
        let allowUnsafeLookup = unsafeToolchainLookupAllowed(environment: environment)
        var rejectionMessages: [String] = []
        let directories = toolSearchDirectories(
            environment: environment,
            allowUnsafeOverrides: !privilegedRuntime || allowUnsafeLookup
        ) + fallbackDirectories

        for directory in directories {
            let candidate = "\(directory)/\(binary)"
            if fileManager.isExecutableFile(atPath: candidate) {
                if privilegedRuntime && !allowUnsafeLookup,
                   let rejectionReason = trustedToolPathRejectionReason(
                       candidate,
                       binaryName: binary,
                       validateCompanionLibrary: ntfsToolNamesRequiringLibrary.contains(binary)
                   ) {
                    rejectionMessages.append("Rejected \(binary) at \(candidate): \(rejectionReason)")
                    continue
                }
                return BinaryResolution(path: candidate, rejectionMessages: rejectionMessages)
            }
        }

        if includePATHLookup,
           (!privilegedRuntime || allowUnsafeLookup),
           let path = Shell.which(binary) {
            if privilegedRuntime && !allowUnsafeLookup,
               let rejectionReason = trustedToolPathRejectionReason(
                   path,
                   binaryName: binary,
                   validateCompanionLibrary: ntfsToolNamesRequiringLibrary.contains(binary)
               ) {
                rejectionMessages.append("Rejected \(binary) at \(path): \(rejectionReason)")
            } else {
                return BinaryResolution(path: path, rejectionMessages: rejectionMessages)
            }
        }

        return BinaryResolution(path: nil, rejectionMessages: rejectionMessages)
    }

    public static func toolSearchDirectories(
        environment: [String: String],
        allowUnsafeOverrides: Bool? = nil
    ) -> [String] {
        var directories: [String] = []
        let includeUnsafeOverrides = allowUnsafeOverrides ?? unsafeToolchainLookupAllowed(environment: environment)

        if includeUnsafeOverrides {
            if let customBin = environment["NTFSACCESS_TOOLCHAIN_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !customBin.isEmpty {
                directories.append(customBin)
            }

            if let customRoot = environment["NTFSACCESS_TOOLCHAIN_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !customRoot.isEmpty {
                directories.append("\(customRoot)/bin")
                directories.append("\(customRoot)/sbin")
            }
        }

        directories.append(contentsOf: [
            NTFSAccessPaths.appBundledToolchainBinPath,
            NTFSAccessPaths.appBundledToolchainSbinPath,
            NTFSAccessPaths.managedToolchainBinPath,
            NTFSAccessPaths.managedToolchainSbinPath,
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ])

        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    public static func unsafeToolchainLookupAllowed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[unsafeToolchainLookupFlag] == "1"
    }

    static func trustedToolPathRejectionReason(
        _ path: String,
        binaryName: String? = nil,
        validateCompanionLibrary: Bool = false
    ) -> String? {
        if let binaryName,
           URL(fileURLWithPath: path).lastPathComponent != binaryName {
            return "expected binary named \(binaryName)"
        }
        if let reason = trustedPathComponentRejectionReason(path, expectedType: .regularFile, requiresExecutable: true) {
            return reason
        }
        if let reason = trustedAncestorDirectoriesRejectionReason(for: path) {
            return reason
        }
        if validateCompanionLibrary,
           let libraryPath = companionLibraryPath(forToolPath: path),
           let reason = trustedPathComponentRejectionReason(libraryPath, expectedType: .regularFile, requiresExecutable: false)
            ?? trustedAncestorDirectoriesRejectionReason(for: libraryPath) {
            return "companion library \(libraryPath) is not trusted: \(reason)"
        }
        return nil
    }

    private enum TrustedPathType {
        case regularFile
        case directory
    }

    private static func trustedPathComponentRejectionReason(
        _ path: String,
        expectedType: TrustedPathType,
        requiresExecutable: Bool
    ) -> String? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            return "path does not exist"
        }

        let type = metadata.st_mode & S_IFMT
        if type == S_IFLNK {
            return "path is a symlink"
        }

        switch expectedType {
        case .regularFile:
            guard type == S_IFREG else {
                return "path is not a regular file"
            }
        case .directory:
            guard type == S_IFDIR else {
                return "path is not a directory"
            }
        }

        guard metadata.st_uid == 0 else {
            return "owner uid \(metadata.st_uid) is not root"
        }
        guard (metadata.st_mode & 0o022) == 0 else {
            return String(format: "mode %o is group/world-writable", metadata.st_mode & 0o777)
        }
        if requiresExecutable {
            guard (metadata.st_mode & 0o111) != 0 else {
                return String(format: "mode %o is not executable", metadata.st_mode & 0o777)
            }
        }
        return nil
    }

    private static func trustedAncestorDirectoriesRejectionReason(for path: String) -> String? {
        var current = URL(fileURLWithPath: path).deletingLastPathComponent().standardized.path
        while !current.isEmpty && current != "/" {
            if let reason = trustedPathComponentRejectionReason(current, expectedType: .directory, requiresExecutable: false) {
                return "directory \(current) is not trusted: \(reason)"
            }
            let parent = URL(fileURLWithPath: current).deletingLastPathComponent().standardized.path
            if parent == current {
                break
            }
            current = parent
        }
        return nil
    }

    private static func companionLibraryPath(forToolPath path: String) -> String? {
        let toolURL = URL(fileURLWithPath: path)
        let toolDirectory = toolURL.deletingLastPathComponent()
        let directoryName = toolDirectory.lastPathComponent
        guard directoryName == "bin" || directoryName == "sbin" else {
            return nil
        }
        return toolDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("lib/libntfs-3g.89.dylib")
            .path
    }

    private static func detectMacFUSEKernelLoaded() -> Bool? {
        guard let result = try? Shell.run("/usr/sbin/kextstat", []) else {
            return nil
        }

        guard result.status == 0 else {
            return nil
        }

        return result.stdoutTrimmed.localizedCaseInsensitiveContains("macfuse")
    }

    private static func installedAppSignatureDescription() -> String {
        signatureDescription(forPath: NTFSAccessPaths.appBundlePath, missingDescription: "not installed")
    }

    private static func signatureDescription(forPath path: String?, missingDescription: String = "not running") -> String {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            return missingDescription
        }

        guard let result = try? Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", path], timeout: 8) else {
            return "unknown"
        }

        let output = result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed
        if output.localizedCaseInsensitiveContains("Signature=adhoc") {
            return "adhoc"
        }
        if let authorityLine = output
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix("Authority=") }) {
            return authorityLine
        }
        if let teamLine = output
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix("TeamIdentifier=") }) {
            return teamLine
        }
        if result.status == 0 {
            return "signed"
        }
        return "unknown"
    }

    private static func runningMountDaemonProgramPath() -> String? {
        guard let result = try? Shell.run("/bin/launchctl", ["print", "system/com.ntfsaccess.mountd"], timeout: 8),
              result.status == 0 else {
            return nil
        }

        let output = result.stdout + "\n" + result.stderr
        for line in output.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("program = ") else {
                continue
            }

            let value = String(trimmed.dropFirst("program = ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        return nil
    }

    private static func installedMountWrapperUsesAppHelper() -> Bool {
        let wrapperPath = "\(NTFSAccessPaths.formatterResourcesPath)/mount_ntfsaccess"
        guard let data = FileManager.default.contents(atPath: wrapperPath),
              let source = String(data: data, encoding: .utf8) else {
            return false
        }

        return source.contains("/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp")
            && source.contains("--mount-helper")
    }

    private static func normalizedArchitecture(_ architecture: String) -> String {
        let trimmed = architecture.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func resolvedArchitecture(_ architecture: String) -> String {
        let trimmed = architecture.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        return currentMachineArchitecture()
    }
}
