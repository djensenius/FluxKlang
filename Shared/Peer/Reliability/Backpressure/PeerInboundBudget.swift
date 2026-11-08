//
//  PeerInboundBudget.swift
//  FluxKlang
//
//  A bounded inbound command budget for one peer connection (#97, R3). Time is a
//  caller-supplied UInt64 tick; this file reads no clock. A fixed window opens at
//  the first admission after a roll and holds at most `commandsPerWindow`
//  admissions; at most `maxInFlight` tickets may be outstanding. The value holds
//  counts and ticket ids only, never payloads. Every limit comes from the
//  throwing factory: there is no default and no forgeable initializer. A ticket
//  is tied to the session of the budget that issued it.
//

/// Proof that one command was admitted; hand it back to `complete` when the command is answered.
/// Only `PeerInboundBudget.admit` makes one. Ids are unique within a budget and never reused. A ticket is tied to the
/// session of the budget that issued it, and another session's budget refuses it. Two budgets of ONE session are one
/// lineage: a restored budget must start past every id the earlier one issued.
struct PeerInboundTicket: Hashable, Sendable {
    let session: PeerSyncSession
    let id: UInt64

    fileprivate init(session: PeerSyncSession, id: UInt64) {
        self.session = session
        self.id = id
    }
}

struct PeerInboundBudget: Hashable, Sendable {
    static let commandBounds = 1...4_096
    static let windowTickBounds: ClosedRange<UInt64> = 1...4_294_967_296
    static let inFlightBounds = 1...1_024

    /// Any session is valid; it only ties the tickets this budget issues to it.
    let session: PeerSyncSession
    let commandsPerWindow: Int
    let windowTicks: UInt64
    let maxInFlight: Int
    /// The tick of the last accepted admission; nil before the first.
    private(set) var lastTick: UInt64?
    /// The tick that opened the current window; nil before the first admission.
    private(set) var windowStart: UInt64?
    private(set) var admittedInWindow = 0
    private var inFlight: Set<UInt64> = []
    /// The id the next ticket gets; nil once the last id (`UInt64.max`) was issued.
    private var nextTicketID: UInt64?

    private init(session: PeerSyncSession, commandsPerWindow: Int, windowTicks: UInt64, maxInFlight: Int,
                 firstTicketID: UInt64) {
        self.session = session
        self.commandsPerWindow = commandsPerWindow
        self.windowTicks = windowTicks
        self.maxInFlight = maxInFlight
        nextTicketID = firstTicketID
    }

    /// Checks the limits in parameter order and names the first bad one. `firstTicketID` is a restore and test
    /// hook (it makes id exhaustion reachable); any value is valid and a fresh budget uses 1.
    static func make(session: PeerSyncSession, commandsPerWindow: Int, windowTicks: UInt64, maxInFlight: Int,
                     firstTicketID: UInt64 = 1) throws(PeerBackpressureRefusal) -> PeerInboundBudget {
        guard commandBounds.contains(commandsPerWindow) else { throw .invalidLimit(.commandsPerWindow) }
        guard windowTickBounds.contains(windowTicks) else { throw .invalidLimit(.windowTicks) }
        guard inFlightBounds.contains(maxInFlight) else { throw .invalidLimit(.maxInFlight) }
        return PeerInboundBudget(session: session, commandsPerWindow: commandsPerWindow, windowTicks: windowTicks,
                                 maxInFlight: maxInFlight, firstTicketID: firstTicketID)
    }

    var inFlightCount: Int { inFlight.count }

    /// Admits one command at tick `now`. Refusal order: `tickRegressed` (`now` below the last accepted tick),
    /// `overBudget`, `inFlightFull`, `overflow` (ticket ids used up). A window rolls when
    /// `now - windowStart >= windowTicks`; the roll is judged before the count, so the Nth admission of a window is
    /// accepted and the N+1th is `overBudget`. Every check runs before any change, so a refusal leaves the whole
    /// value unchanged, even when it would have rolled the window. A tick equal to the last one is accepted.
    mutating func admit(now: UInt64) throws(PeerBackpressureRefusal) -> PeerInboundTicket {
        if let lastTick, now < lastTick { throw .tickRegressed }
        var start = windowStart ?? now
        var admitted = admittedInWindow
        if let current = windowStart {
            // Cannot underflow: each admission stores a `windowStart` that is at most its own `now`, which becomes
            // `lastTick`, and the first guard ensures `now >= lastTick`.
            let elapsed = now - current
            if elapsed >= windowTicks {
                start = now
                admitted = 0
            }
        }
        guard admitted < commandsPerWindow else { throw .overBudget }
        guard inFlight.count < maxInFlight else { throw .inFlightFull }
        guard let id = nextTicketID else { throw .overflow }
        windowStart = start
        admittedInWindow = admitted + 1
        lastTick = now
        nextTicketID = id == UInt64.max ? nil : id + 1
        inFlight.insert(id)
        return PeerInboundTicket(session: session, id: id)
    }

    /// Frees the slot of `ticket`. A ticket of another session, or one that is not in flight (unknown, or already
    /// completed), returns false and changes nothing, so the in-flight count never goes below zero. The session is
    /// checked first.
    @discardableResult
    mutating func complete(_ ticket: PeerInboundTicket) -> Bool {
        guard ticket.session == session else { return false }
        return inFlight.remove(ticket.id) != nil
    }
}
