import Foundation

@objc
public protocol NTFSAccessXPCProtocol {
    // Read-only status calls. These must not change mount daemon state.
    func getServiceState(_ reply: @escaping (ServiceStateDTO) -> Void)
    func getVolumeStates(_ reply: @escaping ([VolumeStateDTO]) -> Void)

    // Mutating calls. The privileged daemon authorizes these from the
    // NSXPCConnection identity; clients must not provide their own identity.
    func scanNow(_ reply: @escaping (OperationResultDTO) -> Void)
    func scanNowBlocking(_ reply: @escaping (OperationResultDTO) -> Void)
    func retryMounts(_ reply: @escaping (OperationResultDTO) -> Void)
    func retryMountsBlocking(_ reply: @escaping (OperationResultDTO) -> Void)
    func repairVolume(stableIdentity: String, actionRawValue: String, reply: @escaping (OperationResultDTO) -> Void)
    func ejectVolume(stableIdentity: String, reply: @escaping (OperationResultDTO) -> Void)
    func setNotificationsEnabled(_ enabled: Bool, reply: @escaping (OperationResultDTO) -> Void)
    func setDurabilityMode(_ modeRawValue: String, reply: @escaping (OperationResultDTO) -> Void)
}

public enum XPCInterfaceFactory {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: NTFSAccessXPCProtocol.self)
        let volumeStateReplyClasses = NSSet(array: [NSArray.self, VolumeStateDTO.self]) as! Set<AnyHashable>
        interface.setClasses(
            volumeStateReplyClasses,
            for: #selector(NTFSAccessXPCProtocol.getVolumeStates(_:)),
            argumentIndex: 0,
            ofReply: true
        )
        return interface
    }
}
