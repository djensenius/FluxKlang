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
        guard let intent = MMCIntent.authorized(message: message, by: policy) else {
            return .refused(.notAuthorized(MMCCommandClass(message.command)))
        }
        return .intent(intent)
    }
}
