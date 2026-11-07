/// Why a lease value could not be constructed. Payloads are the rejected integers or closed enums only.
enum WingLeaseConstructionFault: Error, Equatable, Sendable {
    case grantorNotHuman(WingLeaseOrigin)
    case tickOutOfRange(Int)
    case invalidDuration(Int)
    case invalidBudget(Int)
    case expiryOverflow
}

/// A validated, non-negative integer tick, injected by the caller. The unit is the adapter's choice.
/// The only way to build one is the throwing initializer; comparison is by `rawValue`.
struct WingLeaseTick: Hashable, Comparable, Sendable {
    let rawValue: Int

    /// Valid on `0 ... WingLeaseLimits.maximumTick`; anything else is `.tickOutOfRange(rawValue)`.
    init(_ rawValue: Int) throws(WingLeaseConstructionFault) {
        guard (0 ... WingLeaseLimits.maximumTick).contains(rawValue) else {
            throw .tickOutOfRange(rawValue)
        }
        self.rawValue = rawValue
    }

    static func < (lhs: WingLeaseTick, rhs: WingLeaseTick) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Who a write is attributed to. Mirrors `CommandOrigin` (same cases, same raw values) as an independent type, so the
/// lease has no dependency; the later wiring maps with an exhaustive `switch`.
enum WingLeaseOrigin: String, CaseIterable, Sendable {
    case human
    case controller
    case assistant
}

/// The four phases of a lease. `unleased` allows no traffic and `readOnlyDiscovery` only reads.
enum WingLeasePhase: String, CaseIterable, Sendable {
    case unleased
    case readOnlyDiscovery
    case authorizedWrite
    case restoring
}

/// The seven kinds of event a lease can be asked to apply.
enum WingLeaseEventKind: String, CaseIterable, Sendable {
    case beginDiscovery
    case grant
    case admitWrite
    case beginRestore
    case admitRestoreWrite
    case finishRestore
    case release
}
