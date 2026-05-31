import Foundation

public final class XPCClient {
    private let connection: NSXPCConnection

    public init() {
        self.connection = NSXPCConnection(machServiceName: XPCConstants.machServiceName, options: .privileged)
        self.connection.remoteObjectInterface = XPCInterfaceFactory.make()
        self.connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    public func getServiceState(completion: @escaping (Result<ServiceStateDTO, Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? NTFSAccessXPCProtocol else {
            completion(.failure(XPCClientError.proxyUnavailable))
            return
        }

        proxy.getServiceState { state in
            completion(.success(state))
        }
    }

    public func getVolumeStates(completion: @escaping (Result<[VolumeStateDTO], Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? NTFSAccessXPCProtocol else {
            completion(.failure(XPCClientError.proxyUnavailable))
            return
        }

        proxy.getVolumeStates { states in
            completion(.success(states))
        }
    }

    public func scanNow(completion: @escaping (Result<OperationResultDTO, Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? NTFSAccessXPCProtocol else {
            completion(.failure(XPCClientError.proxyUnavailable))
            return
        }

        proxy.scanNow { result in
            completion(.success(result))
        }
    }

    public func scanNowBlocking(completion: @escaping (Result<OperationResultDTO, Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? NTFSAccessXPCProtocol else {
            completion(.failure(XPCClientError.proxyUnavailable))
            return
        }

        proxy.scanNowBlocking { result in
            completion(.success(result))
        }
    }

    public func retryMounts(completion: @escaping (Result<OperationResultDTO, Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? NTFSAccessXPCProtocol else {
            completion(.failure(XPCClientError.proxyUnavailable))
            return
        }

        proxy.retryMounts { result in
            completion(.success(result))
        }
    }

    public func retryMountsBlocking(completion: @escaping (Result<OperationResultDTO, Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? NTFSAccessXPCProtocol else {
            completion(.failure(XPCClientError.proxyUnavailable))
            return
        }

        proxy.retryMountsBlocking { result in
            completion(.success(result))
        }
    }

    public func repairVolume(
        stableIdentity: String,
        action: VolumeRecoveryActionRaw,
        completion: @escaping (Result<OperationResultDTO, Error>) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? NTFSAccessXPCProtocol else {
            completion(.failure(XPCClientError.proxyUnavailable))
            return
        }

        proxy.repairVolume(stableIdentity: stableIdentity, actionRawValue: action.rawValue) { result in
            completion(.success(result))
        }
    }

    public func ejectVolume(
        stableIdentity: String,
        completion: @escaping (Result<OperationResultDTO, Error>) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? NTFSAccessXPCProtocol else {
            completion(.failure(XPCClientError.proxyUnavailable))
            return
        }

        proxy.ejectVolume(stableIdentity: stableIdentity) { result in
            completion(.success(result))
        }
    }

    public func setNotificationsEnabled(_ enabled: Bool, completion: @escaping (Result<OperationResultDTO, Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? NTFSAccessXPCProtocol else {
            completion(.failure(XPCClientError.proxyUnavailable))
            return
        }

        proxy.setNotificationsEnabled(enabled) { result in
            completion(.success(result))
        }
    }

    public func setDurabilityMode(_ mode: MountDurabilityModeRaw, completion: @escaping (Result<OperationResultDTO, Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? NTFSAccessXPCProtocol else {
            completion(.failure(XPCClientError.proxyUnavailable))
            return
        }

        proxy.setDurabilityMode(mode.rawValue) { result in
            completion(.success(result))
        }
    }

    public func getServiceStateSync(timeout: TimeInterval = 5) throws -> ServiceStateDTO {
        try sync(timeout: timeout, getServiceState)
    }

    public func getVolumeStatesSync(timeout: TimeInterval = 5) throws -> [VolumeStateDTO] {
        try sync(timeout: timeout, getVolumeStates)
    }

    public func scanNowSync(timeout: TimeInterval = 60) throws -> OperationResultDTO {
        try sync(timeout: timeout, scanNow)
    }

    public func scanNowBlockingSync(timeout: TimeInterval = 120) throws -> OperationResultDTO {
        try sync(timeout: timeout, scanNowBlocking)
    }

    public func retryMountsSync(timeout: TimeInterval = 180) throws -> OperationResultDTO {
        try sync(timeout: timeout, retryMounts)
    }

    public func retryMountsBlockingSync(timeout: TimeInterval = 180) throws -> OperationResultDTO {
        try sync(timeout: timeout, retryMountsBlocking)
    }

    public func repairVolumeSync(
        stableIdentity: String,
        action: VolumeRecoveryActionRaw,
        timeout: TimeInterval = 180
    ) throws -> OperationResultDTO {
        try sync(timeout: timeout) { completion in
            repairVolume(stableIdentity: stableIdentity, action: action, completion: completion)
        }
    }

    public func ejectVolumeSync(
        stableIdentity: String,
        timeout: TimeInterval = 60
    ) throws -> OperationResultDTO {
        try sync(timeout: timeout) { completion in
            ejectVolume(stableIdentity: stableIdentity, completion: completion)
        }
    }

    public func setNotificationsEnabledSync(_ enabled: Bool, timeout: TimeInterval = 5) throws -> OperationResultDTO {
        try sync(timeout: timeout) { completion in
            setNotificationsEnabled(enabled, completion: completion)
        }
    }

    public func setDurabilityModeSync(_ mode: MountDurabilityModeRaw, timeout: TimeInterval = 5) throws -> OperationResultDTO {
        try sync(timeout: timeout) { completion in
            setDurabilityMode(mode, completion: completion)
        }
    }

    private func sync<T>(timeout: TimeInterval, _ invoke: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var output: Result<T, Error> = .failure(XPCClientError.timeout)

        invoke { result in
            output = result
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            throw XPCClientError.timeout
        }

        return try output.get()
    }
}

public enum XPCClientError: LocalizedError {
    case proxyUnavailable
    case timeout

    public var errorDescription: String? {
        switch self {
        case .proxyUnavailable:
            return "XPC proxy unavailable"
        case .timeout:
            return "XPC request timed out"
        }
    }
}
