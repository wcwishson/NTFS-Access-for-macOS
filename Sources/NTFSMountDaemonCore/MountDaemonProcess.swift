import Foundation
import Darwin
import NTFSAccessCore
import NTFSAccessShared

public final class MountdXPCService: NSObject, NSXPCListenerDelegate, NTFSAccessXPCProtocol {
    private let stateStore: DaemonStateStore
    private let runner: DaemonRunner
    private let settingsStore: DaemonSettingsStore
    private let orchestrator: NTFSOrchestrator
    private let authorizer: XPCMutatingAuthorizing
    private let rateLimiter: XPCMutationRateLimiting
    private let directClientIdentityProvider: () -> XPCClientIdentity

    public convenience init(
        stateStore: DaemonStateStore,
        runner: DaemonRunner,
        settingsStore: DaemonSettingsStore,
        orchestrator: NTFSOrchestrator
    ) {
        self.init(
            stateStore: stateStore,
            runner: runner,
            settingsStore: settingsStore,
            orchestrator: orchestrator,
            authorizer: MutatingXPCAuthorizer(),
            rateLimiter: XPCMutationRateLimiter(),
            directClientIdentityProvider: XPCClientIdentity.currentProcess
        )
    }

    init(
        stateStore: DaemonStateStore,
        runner: DaemonRunner,
        settingsStore: DaemonSettingsStore,
        orchestrator: NTFSOrchestrator,
        authorizer: XPCMutatingAuthorizing,
        rateLimiter: XPCMutationRateLimiting,
        directClientIdentityProvider: @escaping () -> XPCClientIdentity = XPCClientIdentity.currentProcess
    ) {
        self.stateStore = stateStore
        self.runner = runner
        self.settingsStore = settingsStore
        self.orchestrator = orchestrator
        self.authorizer = authorizer
        self.rateLimiter = rateLimiter
        self.directClientIdentityProvider = directClientIdentityProvider
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = XPCInterfaceFactory.make()
        connection.exportedObject = MountdXPCSession(
            service: self,
            identity: XPCClientIdentity(connection: connection)
        )
        connection.resume()
        return true
    }

    public func getServiceState(_ reply: @escaping (ServiceStateDTO) -> Void) {
        reply(stateStore.currentServiceState())
    }

    public func scanNow(_ reply: @escaping (OperationResultDTO) -> Void) {
        scanNow(client: directClientIdentityProvider(), reply: reply)
    }

    func scanNow(client: XPCClientIdentity, reply: @escaping (OperationResultDTO) -> Void) {
        guard authorize(.scanNow, client: client, reply: reply) else {
            return
        }
        runner.scanNow(reason: "manual xpc")
        reply(OperationResultDTO(success: true, message: "scan queued"))
    }

    public func scanNowBlocking(_ reply: @escaping (OperationResultDTO) -> Void) {
        scanNowBlocking(client: directClientIdentityProvider(), reply: reply)
    }

    func scanNowBlocking(client: XPCClientIdentity, reply: @escaping (OperationResultDTO) -> Void) {
        guard authorize(.scanNowBlocking, client: client, reply: reply) else {
            return
        }
        runner.scanNowBlocking(reason: "manual xpc blocking")
        reply(OperationResultDTO(success: true, message: "scan completed"))
    }

    public func retryMounts(_ reply: @escaping (OperationResultDTO) -> Void) {
        retryMounts(client: directClientIdentityProvider(), reply: reply)
    }

    func retryMounts(client: XPCClientIdentity, reply: @escaping (OperationResultDTO) -> Void) {
        guard authorize(.retryMounts, client: client, reply: reply) else {
            return
        }
        orchestrator.resetRetryState()
        runner.scanNow(reason: "retry mounts after privacy or device state change")
        reply(OperationResultDTO(success: true, message: "retry queued"))
    }

    public func retryMountsBlocking(_ reply: @escaping (OperationResultDTO) -> Void) {
        retryMountsBlocking(client: directClientIdentityProvider(), reply: reply)
    }

    func retryMountsBlocking(client: XPCClientIdentity, reply: @escaping (OperationResultDTO) -> Void) {
        guard authorize(.retryMountsBlocking, client: client, reply: reply) else {
            return
        }
        orchestrator.resetRetryState()
        runner.scanNowBlocking(reason: "retry mounts after privacy or device state change")
        reply(OperationResultDTO(success: true, message: "retry completed"))
    }

    public func ejectVolume(stableIdentity: String, reply: @escaping (OperationResultDTO) -> Void) {
        ejectVolume(stableIdentity: stableIdentity, client: directClientIdentityProvider(), reply: reply)
    }

    func ejectVolume(
        stableIdentity: String,
        client: XPCClientIdentity,
        reply: @escaping (OperationResultDTO) -> Void
    ) {
        guard authorize(.ejectVolume, client: client, reply: reply) else {
            return
        }
        runner.ejectVolumeBlocking(stableIdentity: stableIdentity)
        reply(OperationResultDTO(success: true, message: "ejected"))
    }

    public func repairVolume(
        stableIdentity: String,
        actionRawValue: String,
        reply: @escaping (OperationResultDTO) -> Void
    ) {
        repairVolume(
            stableIdentity: stableIdentity,
            actionRawValue: actionRawValue,
            client: directClientIdentityProvider(),
            reply: reply
        )
    }

    func repairVolume(
        stableIdentity: String,
        actionRawValue: String,
        client: XPCClientIdentity,
        reply: @escaping (OperationResultDTO) -> Void
    ) {
        guard authorize(.repairVolume, client: client, reply: reply) else {
            return
        }
        guard let action = VolumeRecoveryActionRaw(rawValue: actionRawValue) else {
            reply(OperationResultDTO(success: false, message: "Unknown recovery action: \(actionRawValue)"))
            return
        }

        switch action {
        case .none, .openInFinder:
            reply(OperationResultDTO(success: false, message: "Recovery action is not actionable: \(action.rawValue)"))
        case .openFullDiskAccess:
            reply(OperationResultDTO(
                success: true,
                message: "Open System Settings > Privacy & Security > Full Disk Access, enable NTFS Access, then retry."
            ))
        case .showMacFUSEGuidance:
            reply(OperationResultDTO(
                success: true,
                message: "macFUSE needs approval or reinstall before NTFS Access can mount read-write."
            ))
        case .showWindowsCleanupGuidance:
            reply(OperationResultDTO(
                success: true,
                message: "Windows cleanup is required. Shut Windows down fully, disable hibernation/Fast Startup, or run chkdsk, then retry."
            ))
        case .rescan:
            runner.scanVolume(stableIdentity: stableIdentity, reason: "repair rescan")
            reply(OperationResultDTO(success: true, message: "repair queued"))
        case .retryMount, .retryWritableTakeover:
            guard repairTargetIsActionable(stableIdentity: stableIdentity) else {
                reply(OperationResultDTO(success: false, message: "Volume \(stableIdentity) is not actionable. Rescan first if the state changed."))
                return
            }
            runner.repairVolumeBlocking(stableIdentity: stableIdentity, reason: "repair \(action.rawValue)")
            reply(OperationResultDTO(success: true, message: "repair completed"))
        }
    }

    public func setNotificationsEnabled(_ enabled: Bool, reply: @escaping (OperationResultDTO) -> Void) {
        setNotificationsEnabled(enabled, client: directClientIdentityProvider(), reply: reply)
    }

    func setNotificationsEnabled(_ enabled: Bool, client: XPCClientIdentity, reply: @escaping (OperationResultDTO) -> Void) {
        guard authorize(.setNotificationsEnabled, client: client, reply: reply) else {
            return
        }
        do {
            let currentSettings = settingsStore.load()
            try settingsStore.save(DaemonSettings(
                notificationsEnabled: enabled,
                durabilityMode: currentSettings.durabilityMode
            ))
            stateStore.setNotificationsEnabled(enabled)
            reply(OperationResultDTO(success: true, message: "notificationsEnabled=\(enabled)"))
        } catch {
            reply(OperationResultDTO(success: false, message: "Failed to persist notificationsEnabled=\(enabled): \(error.localizedDescription)"))
        }
    }

    public func setDurabilityMode(_ modeRawValue: String, reply: @escaping (OperationResultDTO) -> Void) {
        setDurabilityMode(modeRawValue, client: directClientIdentityProvider(), reply: reply)
    }

    func setDurabilityMode(_ modeRawValue: String, client: XPCClientIdentity, reply: @escaping (OperationResultDTO) -> Void) {
        guard authorize(.setDurabilityMode, client: client, reply: reply) else {
            return
        }
        guard let mode = MountDurabilityMode(rawValue: modeRawValue) else {
            reply(OperationResultDTO(success: false, message: "Unknown durability mode: \(modeRawValue)"))
            return
        }

        do {
            let currentSettings = settingsStore.load()
            try settingsStore.save(DaemonSettings(
                notificationsEnabled: currentSettings.notificationsEnabled,
                durabilityMode: mode
            ))
            stateStore.setDurabilityMode(mode)
            reply(OperationResultDTO(
                success: true,
                message: "durabilityMode=\(mode.rawValue). Remount NTFS volumes for this to affect mount options."
            ))
        } catch {
            reply(OperationResultDTO(success: false, message: "Failed to persist durabilityMode=\(mode.rawValue): \(error.localizedDescription)"))
        }
    }

    public func getVolumeStates(_ reply: @escaping ([VolumeStateDTO]) -> Void) {
        reply(stateStore.currentVolumeStates())
    }

    func sessionForTesting(identity: XPCClientIdentity) -> MountdXPCSession {
        MountdXPCSession(service: self, identity: identity)
    }

    private func authorize(
        _ mutation: XPCMutation,
        client: XPCClientIdentity,
        reply: @escaping (OperationResultDTO) -> Void
    ) -> Bool {
        let authorization = authorizer.authorization(for: mutation, client: client)
        guard authorization.allowed else {
            Log.warning("Denied XPC \(mutation.rawValue) from \(client.logDescription): \(authorization.reason)")
            reply(OperationResultDTO(success: false, message: "Not authorized: \(authorization.reason)"))
            return false
        }

        if mutation.isRateLimited && !rateLimiter.allow(mutation: mutation, client: client, at: Date()) {
            Log.warning("Rate limited XPC \(mutation.rawValue) from \(client.logDescription)")
            reply(OperationResultDTO(success: false, message: "Rate limited: \(mutation.rawValue)"))
            return false
        }

        return true
    }

    private func repairTargetIsActionable(stableIdentity: String) -> Bool {
        stateStore.currentVolumeStates()
            .first { $0.stableIdentity == stableIdentity || $0.deviceIdentifier == stableIdentity }?
            .isActionable == true
    }
}

final class MountdXPCSession: NSObject, NTFSAccessXPCProtocol {
    private let service: MountdXPCService
    private let identity: XPCClientIdentity

    init(service: MountdXPCService, identity: XPCClientIdentity) {
        self.service = service
        self.identity = identity
    }

    func getServiceState(_ reply: @escaping (ServiceStateDTO) -> Void) {
        service.getServiceState(reply)
    }

    func scanNow(_ reply: @escaping (OperationResultDTO) -> Void) {
        service.scanNow(client: identity, reply: reply)
    }

    func scanNowBlocking(_ reply: @escaping (OperationResultDTO) -> Void) {
        service.scanNowBlocking(client: identity, reply: reply)
    }

    func retryMounts(_ reply: @escaping (OperationResultDTO) -> Void) {
        service.retryMounts(client: identity, reply: reply)
    }

    func retryMountsBlocking(_ reply: @escaping (OperationResultDTO) -> Void) {
        service.retryMountsBlocking(client: identity, reply: reply)
    }

    func ejectVolume(stableIdentity: String, reply: @escaping (OperationResultDTO) -> Void) {
        service.ejectVolume(stableIdentity: stableIdentity, client: identity, reply: reply)
    }

    func repairVolume(
        stableIdentity: String,
        actionRawValue: String,
        reply: @escaping (OperationResultDTO) -> Void
    ) {
        service.repairVolume(
            stableIdentity: stableIdentity,
            actionRawValue: actionRawValue,
            client: identity,
            reply: reply
        )
    }

    func setNotificationsEnabled(_ enabled: Bool, reply: @escaping (OperationResultDTO) -> Void) {
        service.setNotificationsEnabled(enabled, client: identity, reply: reply)
    }

    func setDurabilityMode(_ modeRawValue: String, reply: @escaping (OperationResultDTO) -> Void) {
        service.setDurabilityMode(modeRawValue, client: identity, reply: reply)
    }

    func getVolumeStates(_ reply: @escaping ([VolumeStateDTO]) -> Void) {
        service.getVolumeStates(reply)
    }
}

enum XPCMutation: String, CaseIterable {
    case scanNow
    case scanNowBlocking
    case retryMounts
    case retryMountsBlocking
    case repairVolume
    case ejectVolume
    case setNotificationsEnabled
    case setDurabilityMode

    var isRateLimited: Bool {
        rateLimitBucket != nil
    }

    var rateLimitBucket: String? {
        switch self {
        case .scanNow, .scanNowBlocking:
            return "scan"
        case .retryMounts, .retryMountsBlocking, .repairVolume, .ejectVolume:
            return "retry"
        case .setNotificationsEnabled, .setDurabilityMode:
            return nil
        }
    }
}

struct XPCClientIdentity: Equatable {
    let uid: uid_t
    let gid: gid_t
    let pid: pid_t
    let executablePath: String?

    init(uid: uid_t, gid: gid_t, pid: pid_t = 0, executablePath: String? = nil) {
        self.uid = uid
        self.gid = gid
        self.pid = pid
        self.executablePath = executablePath
    }

    init(connection: NSXPCConnection) {
        let pid = connection.processIdentifier
        self.init(
            uid: connection.effectiveUserIdentifier,
            gid: connection.effectiveGroupIdentifier,
            pid: pid,
            executablePath: Self.executablePath(for: pid)
        )
    }

    static func currentProcess() -> XPCClientIdentity {
        XPCClientIdentity(
            uid: getuid(),
            gid: getgid(),
            pid: getpid(),
            executablePath: Self.executablePath(for: getpid())
        )
    }

    var logDescription: String {
        "uid=\(uid) gid=\(gid) pid=\(pid) path=\(executablePath ?? "unknown")"
    }

    private static func executablePath(for pid: pid_t) -> String? {
        guard pid > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else {
            return nil
        }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }
}

struct XPCMutationAuthorization {
    let allowed: Bool
    let reason: String

    static let allowed = XPCMutationAuthorization(allowed: true, reason: "allowed")
}

protocol XPCMutatingAuthorizing {
    func authorization(for mutation: XPCMutation, client: XPCClientIdentity) -> XPCMutationAuthorization
}

struct MutatingXPCAuthorizer: XPCMutatingAuthorizing {
    var consoleUserProvider: () -> ConsoleUser = ConsoleUser.current
    var isAdminProvider: (XPCClientIdentity) -> Bool = Self.isAdmin

    func authorization(for mutation: XPCMutation, client: XPCClientIdentity) -> XPCMutationAuthorization {
        if client.uid == 0 {
            return .allowed
        }

        let consoleUser = consoleUserProvider()
        if client.uid == consoleUser.uid {
            return .allowed
        }

        if isAdminProvider(client) {
            return .allowed
        }

        return XPCMutationAuthorization(
            allowed: false,
            reason: "\(mutation.rawValue) requires root, the signed-in console user, or an admin user"
        )
    }

    private static func isAdmin(_ client: XPCClientIdentity) -> Bool {
        guard let adminGroup = getgrnam("admin")?.pointee else {
            return false
        }

        if client.gid == adminGroup.gr_gid {
            return true
        }

        guard let passwd = getpwuid(client.uid)?.pointee,
              let username = passwd.pw_name else {
            return false
        }
        let usernameString = String(cString: username)

        var memberPointer = adminGroup.gr_mem
        while let member = memberPointer?.pointee {
            if usernameString == String(cString: member) {
                return true
            }
            memberPointer = memberPointer?.advanced(by: 1)
        }

        return false
    }
}

protocol XPCMutationRateLimiting {
    func allow(mutation: XPCMutation, client: XPCClientIdentity, at date: Date) -> Bool
}

final class XPCMutationRateLimiter: XPCMutationRateLimiting {
    private let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var lastAllowedByKey: [String: Date] = [:]

    init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = minimumInterval
    }

    func allow(mutation: XPCMutation, client: XPCClientIdentity, at date: Date) -> Bool {
        guard let bucket = mutation.rateLimitBucket else {
            return true
        }

        let key = "\(client.uid):\(bucket)"
        lock.lock()
        defer { lock.unlock() }

        if let lastAllowed = lastAllowedByKey[key],
           date.timeIntervalSince(lastAllowed) < minimumInterval {
            return false
        }

        lastAllowedByKey[key] = date
        return true
    }
}

public enum MountDaemonProcess {
    public static func run() {
        Log.info("Starting mountd")
        NTFSMounter.restoreDisabledFormatterBundleIfNeeded()

        let settingsStore = DaemonSettingsStore()
        let settings = settingsStore.load()
        let stateStore = DaemonStateStore(
            notificationsEnabled: settings.notificationsEnabled,
            durabilityMode: settings.durabilityMode
        )
        let mountConfiguration = MountConfiguration(durabilityMode: settings.durabilityMode)
        let mounter = try? NTFSMounter(configuration: mountConfiguration)
        let orchestrator = NTFSOrchestrator(
            scanner: DiskScanner(),
            probe: NTFSProbe(),
            mounter: mounter,
            configuration: DaemonConfiguration(),
            mountConfiguration: mountConfiguration
        )

        let runner = DaemonRunner(orchestrator: orchestrator, stateStore: stateStore, configuration: DaemonConfiguration())
        runner.start()

        let service = MountdXPCService(
            stateStore: stateStore,
            runner: runner,
            settingsStore: settingsStore,
            orchestrator: orchestrator
        )
        let listener = NSXPCListener(machServiceName: XPCConstants.machServiceName)
        listener.delegate = service
        listener.resume()

        RunLoop.main.run()
    }
}
