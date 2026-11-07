/// The request an authorized inbound MMC message becomes: which device id it carried and what it asked for.
///
/// A pure value. It carries no authority token and no function on it starts, stops, locates or sends anything;
/// the host decides what to do with it. It can only be created by `authorized(message:by:)`, which checks the
/// policy, so holding an intent means the policy admitted that exact message. A locate intent keeps the exact
/// `MMCLocateTarget` (time, subframes, colour-frame flag); no frame conversion happens here.
struct MMCIntent: Equatable, Hashable, Sendable {
    let deviceID: SysExDeviceID
    private(set) var command: MMCCommand

    var commandClass: MMCCommandClass { MMCCommandClass(command) }

    var locateTarget: MMCLocateTarget? {
        guard case let .locate(target) = command else { return nil }
        return target
    }

    private init(deviceID: SysExDeviceID, command: MMCCommand) {
        self.deviceID = deviceID
        self.command = command
    }

    /// Returns an intent only when `policy` admits the message's device id and command class, otherwise nil.
    static func authorized(message: MMCMessage, by policy: MMCAuthorization) -> MMCIntent? {
        let commandClass = MMCCommandClass(message.command)
        guard policy.admits(deviceID: message.deviceID, commandClass: commandClass) else { return nil }
        return MMCIntent(deviceID: message.deviceID, command: message.command)
    }
}
