/// The request an authorized inbound MMC message becomes: which device id it carried and what it asked for.
///
/// A pure value. It carries no authority token and no function on it starts, stops, locates or sends anything;
/// the host decides what to do with it. It can only be created by `MMCIntentGate.evaluate`, which checks
/// addressing and then the policy, so holding an intent means the receiver was addressed and the policy admitted
/// that exact message. A locate intent keeps the exact `MMCLocateTarget` (time, subframes, colour-frame flag);
/// no frame conversion happens here.
struct MMCIntent: Equatable, Hashable, Sendable {
    let deviceID: SysExDeviceID
    private(set) var command: MMCCommand

    var commandClass: MMCCommandClass { MMCCommandClass(command) }

    var locateTarget: MMCLocateTarget? {
        guard case let .locate(target) = command else { return nil }
        return target
    }

    fileprivate init(deviceID: SysExDeviceID, command: MMCCommand) {
        self.deviceID = deviceID
        self.command = command
    }
}

/// Why an addressed message did not become an intent.
enum MMCIntentRefusal: Error, Equatable, Hashable, Sendable {
    /// Default deny: no policy entry admits this command class for the message's device id.
    case notAuthorized(MMCCommandClass)
}

/// The outcome of evaluating one decoded MMC message.
enum MMCIntentDecision: Equatable, Hashable, Sendable {
    /// Addressed to another device: not for this receiver, so neither an intent nor a refusal.
    case ignored
    case refused(MMCIntentRefusal)
    case intent(MMCIntent)
}

/// Turns a decoded `MMCMessage` into an intent only when the policy explicitly allows it. Pure and stateless:
/// it never executes transport, never re-parses bytes and takes no tempo-sharing or other optional integration.
enum MMCIntentGate {
    /// Addressing uses `MMCMessage.decode` semantics: an exact device id match or all-call is addressed to
    /// `receiver`. Addressing is checked first; an unaddressed message is `.ignored` even if it would be refused.
    static func evaluate(message: MMCMessage, policy: MMCAuthorization, receiver: SysExDeviceID) -> MMCIntentDecision {
        guard message.deviceID.addresses(receiver) else { return .ignored }
        let commandClass = MMCCommandClass(message.command)
        guard policy.admits(deviceID: message.deviceID, commandClass: commandClass) else {
            return .refused(.notAuthorized(commandClass))
        }
        return .intent(MMCIntent(deviceID: message.deviceID, command: message.command))
    }
}
