//
//  OpenSoundControl+IntakeBudget.swift
//  FluxKlang
//
//  The per-peer intake allowance and its ledger (#89, O2b). A peer may charge
//  at most `maximumPackets` packets and `maximumBytes` bytes per window; a
//  peer that sends more than `maximumMalformed` malformed inputs in one window
//  is quarantined for `cooldownTicks`. Time is an injected tick: the ledger
//  never reads a clock, never adds ticks (it subtracts an earlier tick from a
//  later one after an ordering check) and never steps backwards. A tick has no
//  ceiling: every `UInt64`, `.max` included, is valid and cannot overflow.
//

extension OpenSoundControl {
    /// The allowance one peer gets per window. Validated once; private storage afterwards.
    struct IntakeBudget: Sendable, Hashable {
        static let packetLimit = 65_536
        static let byteLimit = 1 << 30
        static let malformedLimit = 1_024

        /// Window length; at least 1.
        private(set) var windowTicks: UInt64
        /// Packets (datagrams or stream frames) per window, 1 through `packetLimit`.
        private(set) var maximumPackets: Int
        /// Bytes per window, 1 through `byteLimit`.
        private(set) var maximumBytes: Int
        /// Malformed inputs tolerated per window, 0 through `malformedLimit`; the next one quarantines.
        private(set) var maximumMalformed: Int
        /// Quarantine length; at least 1.
        private(set) var cooldownTicks: UInt64

        /// Validation order: window, packets, bytes, malformed, cooldown.
        init(
            windowTicks: UInt64, maximumPackets: Int, maximumBytes: Int, maximumMalformed: Int, cooldownTicks: UInt64
        ) throws(EndpointRefusal) {
            guard windowTicks >= 1 else { throw .invalidTicks(.window, windowTicks) }
            guard (1...Self.packetLimit).contains(maximumPackets) else { throw .invalidCount(.packets, maximumPackets) }
            guard (1...Self.byteLimit).contains(maximumBytes) else { throw .invalidCount(.bytes, maximumBytes) }
            guard (0...Self.malformedLimit).contains(maximumMalformed) else {
                throw .invalidCount(.malformed, maximumMalformed)
            }
            guard cooldownTicks >= 1 else { throw .invalidTicks(.cooldown, cooldownTicks) }
            self.windowTicks = windowTicks
            self.maximumPackets = maximumPackets
            self.maximumBytes = maximumBytes
            self.maximumMalformed = maximumMalformed
            self.cooldownTicks = cooldownTicks
        }
    }

    /// Every typed refusal of one intake call. A gate refusal (any case but `malformed` and `notAdmitted`, when
    /// it refuses a whole call) changes nothing: not the pipeline, a ledger, the latest tick, or the stream bytes
    /// the caller offered. `malformed` and `notAdmitted` are refusals of an input that was already charged.
    ///
    /// Only `peerQuarantined`, `packetBudgetExceeded` and `byteBudgetExceeded` carry `retryAfterTicks`: the
    /// same call is admitted past that gate once that many more ticks have passed (not one fewer), provided
    /// the peer is charged for nothing else meanwhile. The pipeline never raises a byte refusal for an input
    /// that can never fit the allowance: it refuses such a datagram as `datagramTooLarge`, and a policy
    /// cannot be built whose allowance is below one stream chunk. So every hint it gives can come true.
    ///
    /// `peerQuarantined` and `packetBudgetExceeded` can also be one frame's result inside `ChunkOutcome.consumed`,
    /// when the peer was quarantined or used up its packets earlier in the same chunk. That is not a gate
    /// refusal: the chunk was consumed in full and its bytes charged, only that frame was dropped (uncharged and
    /// not decoded), and its hint is for the next frame the peer sends, not for a retry of the chunk.
    enum IntakeRefusal: Error, Sendable, Hashable {
        case endpointDisabled
        /// A datagram call on a stream endpoint, or the reverse. Carries the endpoint's transport.
        case wrongTransport(expected: EndpointTransport)
        /// Injected time must never run backwards. An equal tick is allowed.
        case tickRegressed(previous: UInt64, now: UInt64)
        /// A stream chunk above `EndpointPolicy.maximumChunkBytes`; offer it in smaller pieces.
        case chunkTooLarge(byteCount: Int, limit: Int)
        /// A datagram above the whole byte allowance (`IntakeBudget.maximumBytes`). No window can ever hold it,
        /// so unlike `byteBudgetExceeded` there is no retry hint. A datagram within the allowance but above the
        /// policy's packet size is charged and refused as `malformed` instead.
        case datagramTooLarge(byteCount: Int, limit: Int)
        /// An unknown peer while the table is full. Nothing is ever evicted to make room.
        case peerTableFull(limit: Int)
        /// The peer is quarantined; the same call succeeds once `retryAfterTicks` more ticks have passed.
        case peerQuarantined(retryAfterTicks: UInt64)
        /// The window's packets are used up; the window rolls after `retryAfterTicks` more ticks.
        case packetBudgetExceeded(limit: Int, retryAfterTicks: UInt64)
        /// The window's bytes would be exceeded; the window rolls after `retryAfterTicks` more ticks.
        case byteBudgetExceeded(limit: Int, retryAfterTicks: UInt64)
        /// The codec or framer refused the input. Charged as packet, bytes and one malformed input.
        case malformed(CodecError)
        /// A valid packet the immediate stage refused (wildcard, unlisted address, scheduled tag, reserved
        /// tag). Charged as packet and bytes only: never as malformed.
        case notAdmitted(SchedulingRefusal)
    }

    /// What one peer has been charged in its current window. A functional value: each step returns
    /// the next ledger or throws and leaves the original untouched. The window starts at the peer's
    /// first charged tick; a roll opens the next window at the rolling call's tick and resets packets,
    /// bytes and malformed. A quarantined peer is refused until `cooldownTicks` after the tick that
    /// quarantined it, then released into a fresh window. Invariant:
    /// `windowStart <= lastActivity`, `quarantinedAt <= lastActivity`, `packets <= maximumPackets` and
    /// `bytes <= maximumBytes`.
    struct PeerLedger: Sendable, Hashable {
        private(set) var windowStart: UInt64
        private(set) var packets: Int
        private(set) var bytes: Int
        private(set) var malformed: Int
        private(set) var quarantinedAt: UInt64?
        /// The latest tick that charged this peer.
        private(set) var lastActivity: UInt64

        private init(tick: UInt64) {
            windowStart = tick
            packets = 0
            bytes = 0
            malformed = 0
            quarantinedAt = nil
            lastActivity = tick
        }

        /// A new peer's ledger: an empty window starting at `tick`.
        static func fresh(at tick: UInt64) -> PeerLedger { PeerLedger(tick: tick) }

        /// Charges one datagram: its bytes and one packet. `byteCount` is an array count (not negative). A
        /// count above `maximumBytes` would be refused as `byteBudgetExceeded` with a hint that can never come
        /// true; the pipeline refuses such a datagram earlier, as `datagramTooLarge`, and never asks.
        func admittingDatagram(
            byteCount: Int, at tick: UInt64, budget: IntakeBudget
        ) throws(IntakeRefusal) -> PeerLedger {
            try admitting(byteCount: byteCount, packetCharge: 1, at: tick, budget: budget)
        }

        /// Charges one stream chunk's bytes. It needs room for one packet but charges none: frames charge themselves.
        /// A policy guarantees `maximumBytes` holds a whole chunk, so a byte refusal here always has a way out.
        func admittingChunk(byteCount: Int, at tick: UInt64, budget: IntakeBudget) throws(IntakeRefusal) -> PeerLedger {
            try admitting(byteCount: byteCount, packetCharge: 0, at: tick, budget: budget)
        }

        /// Charges one frame of an already charged chunk: one packet, no bytes.
        func admittingFrame(at tick: UInt64, budget: IntakeBudget) throws(IntakeRefusal) -> PeerLedger {
            try admitting(byteCount: 0, packetCharge: 1, at: tick, budget: budget)
        }

        /// Charges one malformed input. The input that exceeds `maximumMalformed` quarantines the peer at
        /// `tick`; a peer that is already quarantined keeps its original quarantine tick.
        func chargingMalformed(at tick: UInt64, budget: IntakeBudget) -> PeerLedger {
            guard quarantinedAt == nil else { return self }
            var next = self
            next.malformed += 1
            next.lastActivity = Swift.max(lastActivity, tick)
            if next.malformed > budget.maximumMalformed { next.quarantinedAt = tick }
            return next
        }

        /// Whether a call at `tick` would be refused as quarantined. A tick before the quarantine began counts.
        func isQuarantined(at tick: UInt64, budget: IntakeBudget) -> Bool {
            guard let quarantinedAt else { return false }
            return tick < quarantinedAt || tick - quarantinedAt < budget.cooldownTicks
        }

        /// Whether the peer has been quiet for `idleTicks` and is free of quarantine at `tick`. Idle expiry
        /// only ever drops a peer whose window would roll (or whose quarantine would release) on its next call.
        func isIdle(at tick: UInt64, budget: IntakeBudget, idleTicks: UInt64) -> Bool {
            !isQuarantined(at: tick, budget: budget) && tick >= lastActivity && tick - lastActivity >= idleTicks
        }

        /// The ledger as of `tick`: an elapsed quarantine is released and a due window rolled, each into a
        /// fresh window at `tick`. A quarantine that has not elapsed refuses.
        private func current(at tick: UInt64, budget: IntakeBudget) throws(IntakeRefusal) -> PeerLedger {
            guard tick >= lastActivity else { throw .tickRegressed(previous: lastActivity, now: tick) }
            if let quarantinedAt {
                let elapsed = tick - quarantinedAt
                guard elapsed >= budget.cooldownTicks else {
                    throw .peerQuarantined(retryAfterTicks: budget.cooldownTicks - elapsed)
                }
                return PeerLedger.fresh(at: tick)
            }
            return tick - windowStart >= budget.windowTicks ? PeerLedger.fresh(at: tick) : self
        }

        /// Packet room is checked before byte room; both before anything is charged.
        private func admitting(
            byteCount: Int, packetCharge: Int, at tick: UInt64, budget: IntakeBudget
        ) throws(IntakeRefusal) -> PeerLedger {
            var next = try current(at: tick, budget: budget)
            let retryAfter = budget.windowTicks - (tick - next.windowStart)
            guard next.packets < budget.maximumPackets else {
                throw .packetBudgetExceeded(limit: budget.maximumPackets, retryAfterTicks: retryAfter)
            }
            guard byteCount <= budget.maximumBytes - next.bytes else {
                throw .byteBudgetExceeded(limit: budget.maximumBytes, retryAfterTicks: retryAfter)
            }
            next.packets += packetCharge
            next.bytes += byteCount
            next.lastActivity = tick
            return next
        }
    }
}
