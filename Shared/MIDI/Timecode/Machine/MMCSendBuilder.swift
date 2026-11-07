/// Why a grant did not allow building a message.
enum MMCSendRefusal: Error, Equatable, Hashable, Sendable {
    case notYetValid(now: Int, issuedAt: Int)
    case expired(now: Int, expiresAt: Int)
    case commandClassNotGranted(MMCCommandClass)
}

/// Builds an outbound `MMCMessage` value only under a valid grant. It never sends, encodes to a transport or
/// touches a device; the caller decides what happens to the returned value.
enum MMCSendBuilder {
    /// The message is addressed to `grant.target`. Time is checked before scope (`notYetValid`, then `expired`,
    /// then `commandClassNotGranted`), so an expired grant reveals nothing about its scope.
    static func message(for command: MMCCommand, grant: MMCSendGrant, now: Int) throws(MMCSendRefusal) -> MMCMessage {
        guard now >= grant.issuedAt else { throw .notYetValid(now: now, issuedAt: grant.issuedAt) }
        guard now < grant.expiresAt else { throw .expired(now: now, expiresAt: grant.expiresAt) }
        let commandClass = MMCCommandClass(command)
        guard grant.commandClasses.contains(commandClass) else { throw .commandClassNotGranted(commandClass) }
        return MMCMessage(deviceID: grant.target, command: command)
    }
}
