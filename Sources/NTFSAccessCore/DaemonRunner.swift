import Darwin
import DiskArbitration
import Foundation

public final class DaemonRunner: @unchecked Sendable {
    private let orchestrator: NTFSOrchestrator
    private let stateStore: DaemonStateStore
    private let configuration: DaemonConfiguration
    private let scanQueue = DispatchQueue(label: "com.ntfsaccess.mountd.scan")
    private let scanQueueKey = DispatchSpecificKey<Void>()
    private let requestLock = NSLock()

    private var scanTimer: DispatchSourceTimer?
    private var signalIntSource: DispatchSourceSignal?
    private var signalTermSource: DispatchSourceSignal?
    private var diskSession: DASession?
    private var scanInProgress = false
    private var scanWorkScheduled = false
    private var scanQueued = false

    public init(
        orchestrator: NTFSOrchestrator,
        stateStore: DaemonStateStore,
        configuration: DaemonConfiguration = DaemonConfiguration()
    ) {
        self.orchestrator = orchestrator
        self.stateStore = stateStore
        self.configuration = configuration
        self.scanQueue.setSpecific(key: scanQueueKey, value: ())
    }

    public func start() {
        installSignalHandlers()
        installDiskWatcher()
        installPeriodicScan()
        triggerScan(reason: "startup")
        Log.info("mountd started")
    }

    public func triggerScan(reason: String) {
        guard scheduleScan(reason: reason) else {
            return
        }

        scanQueue.async { [weak self] in
            self?.runCoalescedScans(initialReason: reason)
        }
    }

    public func scanNow(reason: String) {
        triggerScan(reason: reason)
    }

    public func scanNowBlocking(reason: String) {
        guard scheduleScan(reason: reason) else {
            syncWithScanQueue()
            return
        }

        scanQueue.sync { [weak self] in
            self?.runCoalescedScans(initialReason: reason)
        }
    }

    public func scanVolume(stableIdentity: String, reason: String) {
        scanQueue.async { [weak self] in
            self?.runTargetedScan(stableIdentity: stableIdentity, reason: reason)
        }
    }

    public func scanVolumeBlocking(stableIdentity: String, reason: String) {
        if DispatchQueue.getSpecific(key: scanQueueKey) != nil {
            runTargetedScan(stableIdentity: stableIdentity, reason: reason)
            return
        }

        scanQueue.sync { [weak self] in
            self?.runTargetedScan(stableIdentity: stableIdentity, reason: reason)
        }
    }

    public func repairVolumeBlocking(stableIdentity: String, reason: String) {
        if DispatchQueue.getSpecific(key: scanQueueKey) != nil {
            runTargetedRepair(stableIdentity: stableIdentity, reason: reason)
            return
        }

        scanQueue.sync { [weak self] in
            self?.runTargetedRepair(stableIdentity: stableIdentity, reason: reason)
        }
    }

    public func ejectVolumeBlocking(stableIdentity: String) {
        if DispatchQueue.getSpecific(key: scanQueueKey) != nil {
            runEjectVolume(stableIdentity: stableIdentity)
            return
        }

        scanQueue.sync { [weak self] in
            self?.runEjectVolume(stableIdentity: stableIdentity)
        }
    }

    private func scheduleScan(reason: String) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }

        if scanWorkScheduled {
            scanQueued = true
            Log.info("Coalescing scan request while busy: \(reason)")
            return false
        }

        scanWorkScheduled = true
        return true
    }

    private func syncWithScanQueue() {
        if DispatchQueue.getSpecific(key: scanQueueKey) != nil {
            return
        }
        scanQueue.sync {}
    }

    private func runCoalescedScans(initialReason: String) {
        var reason = initialReason
        while true {
            runScan(reason: reason)

            requestLock.lock()
            if scanQueued {
                scanQueued = false
                requestLock.unlock()
                reason = "coalesced"
                continue
            }
            scanWorkScheduled = false
            requestLock.unlock()
            return
        }
    }

    private func runScan(reason: String) {
        scanInProgress = true
        stateStore.beginOperation(.scanning, message: reason)
        defer {
            scanInProgress = false
            stateStore.finishOperation()
        }

        Log.info("Running scan: \(reason)")
        let result = orchestrator.reconcile()
        stateStore.update(from: result)
    }

    private func runTargetedScan(stableIdentity: String, reason: String) {
        scanInProgress = true
        stateStore.beginOperation(.scanning, message: "\(reason): \(stableIdentity)")
        defer {
            scanInProgress = false
            stateStore.finishOperation()
        }

        Log.info("Running targeted scan for \(stableIdentity): \(reason)")
        let result = orchestrator.reconcileKnownVolume(stableIdentity: stableIdentity)
        stateStore.update(from: result)
    }

    private func runTargetedRepair(stableIdentity: String, reason: String) {
        scanInProgress = true
        stateStore.beginOperation(.repairing, message: "\(reason): \(stableIdentity)")
        defer {
            scanInProgress = false
            stateStore.finishOperation()
        }

        Log.info("Repairing volume \(stableIdentity): \(reason)")
        orchestrator.resetRetryState(for: stableIdentity)
        let result = orchestrator.reconcileKnownVolume(stableIdentity: stableIdentity)
        stateStore.update(from: result)
    }

    private func runEjectVolume(stableIdentity: String) {
        scanInProgress = true
        stateStore.beginOperation(.repairing, message: "eject: \(stableIdentity)")
        defer {
            scanInProgress = false
            stateStore.finishOperation()
        }

        Log.info("Ejecting volume \(stableIdentity)")
        let result = orchestrator.ejectVolume(stableIdentity: stableIdentity)
        stateStore.update(from: result)
    }

    private func installPeriodicScan() {
        let timer = DispatchSource.makeTimerSource(queue: scanQueue)
        timer.schedule(deadline: .now() + configuration.scanIntervalSeconds, repeating: configuration.scanIntervalSeconds)
        timer.setEventHandler { [weak self] in
            self?.triggerScan(reason: "interval")
        }
        timer.resume()
        scanTimer = timer
    }

    private func installDiskWatcher() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            Log.warning("Disk Arbitration session not available; continuing with periodic scans")
            return
        }

        diskSession = session

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, daemonDiskAppearedCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, daemonDiskDisappearedCallback, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, daemonDiskDescriptionChangedCallback, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func handleDiskAppeared() {
        triggerScan(reason: "disk appeared")
    }

    func handleDiskDisappeared() {
        triggerScan(reason: "disk disappeared")
    }

    func handleDiskDescriptionChanged() {
        triggerScan(reason: "disk changed")
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler {
            Log.info("Received SIGINT")
            CFRunLoopStop(CFRunLoopGetMain())
        }
        intSource.resume()
        signalIntSource = intSource

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler {
            Log.info("Received SIGTERM")
            CFRunLoopStop(CFRunLoopGetMain())
        }
        termSource.resume()
        signalTermSource = termSource
    }
}

private func daemonRunnerFromContext(_ context: UnsafeMutableRawPointer?) -> DaemonRunner? {
    guard let context else {
        return nil
    }
    return Unmanaged<DaemonRunner>.fromOpaque(context).takeUnretainedValue()
}

private let daemonDiskAppearedCallback: DADiskAppearedCallback = { _, context in
    guard let runner = daemonRunnerFromContext(context) else {
        return
    }
    runner.handleDiskAppeared()
}

private let daemonDiskDisappearedCallback: DADiskDisappearedCallback = { _, context in
    guard let runner = daemonRunnerFromContext(context) else {
        return
    }
    runner.handleDiskDisappeared()
}

private let daemonDiskDescriptionChangedCallback: DADiskDescriptionChangedCallback = { _, _, context in
    guard let runner = daemonRunnerFromContext(context) else {
        return
    }
    runner.handleDiskDescriptionChanged()
}
