/// Typed refusals when building a send grant.
enum MMCSendGrantError: Error, Equatable, Hashable, Sendable {
    case emptyCommandClasses
    /// The smallest class listed more than once.
    case duplicateCommandClass(MMCCommandClass)
    /// A grant never targets all-call: a broadcast transport command needs one explicit device id per target.
    case broadcastTarget
    /// `issuedAt` must be >= 0 and `expiresAt` must be greater than `issuedAt`.
    case invalidWindow(issuedAt: Int, expiresAt: Int)
}

/// An explicit permission to BUILD outbound MMC for one named device id and a fixed set of command classes,
/// valid for the half-open tick window `[issuedAt, expiresAt)`.
///
/// Ticks are caller-supplied integers; this lane has no clock or timer. The grant is an inert value used
/// only by `MMCSendBuilder`. It does not send anything, is not consumed by use and has no revocation: single-use
/// and revocation belong to the caller. A grant for `play` never covers `record`.
struct MMCSendGrant: Equatable, Hashable, Sendable {
    let target: SysExDeviceID
    /// Granted classes in ascending raw order.
    private(set) var commandClasses: [MMCCommandClass]
    let issuedAt: Int
    let expiresAt: Int

    private init(target: SysExDeviceID, commandClasses: [MMCCommandClass], issuedAt: Int, expiresAt: Int) {
        self.target = target
        self.commandClasses = commandClasses
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// Check order: empty classes, duplicate class (smallest), all-call target, window.
    static func make(
        target: SysExDeviceID,
        commandClasses: [MMCCommandClass],
        issuedAt: Int,
        expiresAt: Int
    ) throws(MMCSendGrantError) -> MMCSendGrant {
        guard !commandClasses.isEmpty else { throw .emptyCommandClasses }
        let sorted = commandClasses.sorted()
        for index in sorted.indices.dropFirst() where sorted[index] == sorted[index - 1] {
            throw .duplicateCommandClass(sorted[index])
        }
        guard !target.isAllCall else { throw .broadcastTarget }
        guard issuedAt >= 0, expiresAt > issuedAt else {
            throw .invalidWindow(issuedAt: issuedAt, expiresAt: expiresAt)
        }
        return MMCSendGrant(target: target, commandClasses: sorted, issuedAt: issuedAt, expiresAt: expiresAt)
    }
}
