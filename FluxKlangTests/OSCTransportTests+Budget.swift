import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Per-peer budgets, quarantine, the peer table and idle expiry (#89, O2b).
extension OSCTransportTests {
    // MARK: Packet and byte windows

    @Test("A window admits N packets and refuses packet N+1 before decoding it")
    func packetWindowAdmitsNAndRefusesNPlusOne() throws {
        var pipeline = try Fixture.pipeline()
        for step in 0..<4 {
            #expect(try Fixture.go(&pipeline, Int32(step), at: UInt64(step)) == Fixture.accepted(Int32(step)))
        }
        let refusal = Refusal.packetBudgetExceeded(limit: 4, retryAfterTicks: 6)
        // Garbage would be `malformed` if it were decoded; the budget refusal comes first and charges nothing.
        #expect(Fixture.receive(&pipeline, Fixture.garbage, at: 4) == .failure(refusal))
        #expect(try Fixture.go(&pipeline, at: 4) == .failure(refusal))
        let ledger = try Fixture.ledger(pipeline)
        #expect(ledger.packets == 4 && ledger.bytes == 48 && ledger.malformed == 0 && ledger.quarantinedAt == nil)
    }

    @Test("A window admits N bytes and refuses a datagram that would make it N+1, before decoding it")
    func byteWindowAdmitsNAndRefusesNPlusOne() throws {
        var pipeline = try Fixture.pipeline(packets: 8, bytes: 36, packetBytes: 36)
        for step in 0..<3 {
            #expect(try Fixture.go(&pipeline, at: UInt64(step)) == Fixture.accepted())
        }
        #expect(try Fixture.ledger(pipeline).bytes == 36)
        let refusal = Refusal.byteBudgetExceeded(limit: 36, retryAfterTicks: 7)
        #expect(Fixture.receive(&pipeline, [0], at: 3) == .failure(refusal))
        #expect(Fixture.receive(&pipeline, Fixture.garbage, at: 3) == .failure(refusal))
        let ledger = try Fixture.ledger(pipeline)
        #expect(ledger.packets == 3 && ledger.bytes == 36 && ledger.malformed == 0)
    }

    @Test("A datagram exactly as large as the byte allowance is admitted; one byte more can never fit")
    func singleDatagramAgainstTheByteAllowance() throws {
        var pipeline = try Fixture.pipeline(bytes: 12, packetBytes: 12)
        let tooBig = [UInt8](repeating: 0, count: 13)
        // No window could ever hold it, so unlike a budget refusal this one carries no retry hint.
        let refusal = Refusal.datagramTooLarge(byteCount: 13, limit: 12)
        #expect(Fixture.receive(&pipeline, tooBig, at: 0) == .failure(refusal))
        #expect(Fixture.receive(&pipeline, tooBig, at: 1_000) == .failure(refusal))
        #expect(pipeline.peerCount == 0 && pipeline.latestTick == nil)
        #expect(try Fixture.go(&pipeline, at: 0) == Fixture.accepted())
        #expect(try Fixture.ledger(pipeline).bytes == 12)
        // The limit it reports is the byte allowance (24 here), not the policy's packet size (12).
        var roomy = try Fixture.pipeline(bytes: 24, packetBytes: 12)
        let reported = Refusal.datagramTooLarge(byteCount: 25, limit: 24)
        #expect(Fixture.receive(&roomy, [UInt8](repeating: 0, count: 25), at: 0) == .failure(reported))
    }

    @Test("A datagram above the whole byte allowance is refused after the tick gate and before any peer gate")
    func oversizedDatagramIsRefusedBeforeAnyPeerGate() throws {
        let tooBig = [UInt8](repeating: 0x2F, count: 25)
        let refusal = Refusal.datagramTooLarge(byteCount: 25, limit: 24)
        var pipeline = try Fixture.pipeline(packets: 1, bytes: 24, malformed: 0, peers: 1, packetBytes: 24)
        // First contact: it takes no peer slot and records no tick.
        #expect(Fixture.receive(&pipeline, tooBig, at: 0) == .failure(refusal))
        #expect(pipeline.peerCount == 0 && pipeline.latestTick == nil)
        // The allowance itself is admitted. That peer then has no packet left and fills the one-peer table.
        let wide = try Fixture.datagram(7, "/mixer/3/fader")
        let fits = try Fixture.accepted(7, "/mixer/3/fader")
        #expect(Fixture.receive(&pipeline, wide, at: 1) == fits)
        // The table gate would refuse a new peer and the packet gate this one, but the size comes first.
        #expect(Fixture.receive(&pipeline, tooBig, from: Fixture.bravo, at: 2) == .failure(refusal))
        #expect(Fixture.receive(&pipeline, tooBig, at: 2) == .failure(refusal))
        #expect(pipeline.latestTick == 1 && pipeline.peerKeys == [Fixture.alpha])
        // Only a disabled endpoint, the wrong transport and a regressed tick come before it.
        #expect(Fixture.receive(&pipeline, tooBig, at: 0) == .failure(.tickRegressed(previous: 1, now: 0)))
        var disabled = OSC.IntakePipeline()
        #expect(Fixture.receive(&disabled, tooBig, at: 0) == .failure(.endpointDisabled))
        var stream = try Fixture.stream(.slip)
        let wrong = Refusal.wrongTransport(expected: .stream(.slip))
        #expect(Fixture.receive(&stream, [UInt8](repeating: 0x2F, count: 1_025), at: 0) == .failure(wrong))
        // A quarantined peer is told the size first, and the quarantine once the call is small enough.
        var jailed = try Fixture.pipeline(bytes: 24, malformed: 0, packetBytes: 24)
        #expect(Fixture.receive(&jailed, Fixture.garbage, at: 0) == .failure(.malformed(.unrecognizedPacket)))
        #expect(Fixture.receive(&jailed, tooBig, at: 1) == .failure(refusal))
        #expect(try Fixture.go(&jailed, at: 1) == .failure(.peerQuarantined(retryAfterTicks: 19)))
        // The limit is the byte allowance, not the packet size: 24 bytes are charged, and are malformed for a
        // 12 byte packet size, while 25 bytes are refused without a charge.
        var small = try Fixture.pipeline(bytes: 24, packetBytes: 12)
        let packet = Refusal.malformed(.packetTooLarge(byteCount: 24, limit: 12))
        #expect(Fixture.receive(&small, [UInt8](repeating: 0x2F, count: 24), at: 0) == .failure(packet))
        #expect(Fixture.receive(&small, tooBig, at: 0) == .failure(refusal))
        let ledger = try Fixture.ledger(small)
        #expect(ledger.packets == 1 && ledger.bytes == 24 && ledger.malformed == 1)
    }

    @Test("The window rolls at exactly windowTicks after it started; the next window starts at the rolling tick")
    func windowRollsAtTheExactTick() throws {
        var pipeline = try Fixture.pipeline(packets: 1)
        #expect(try Fixture.go(&pipeline, at: 3) == Fixture.accepted())
        // A wrong window start would make the calls below trap on a subtraction instead of fail: stop here.
        let started = try Fixture.ledger(pipeline).windowStart
        #expect(started == 3)
        guard started == 3 else { return }
        let last = Refusal.packetBudgetExceeded(limit: 1, retryAfterTicks: 1)
        #expect(try Fixture.go(&pipeline, at: 12) == .failure(last))
        #expect(try Fixture.go(&pipeline, at: 13) == Fixture.accepted())
        let rolled = try Fixture.ledger(pipeline)
        #expect(rolled.windowStart == 13 && rolled.packets == 1 && rolled.bytes == 12 && rolled.lastActivity == 13)
        #expect(try Fixture.go(&pipeline, at: 22) == .failure(last))
        #expect(try Fixture.go(&pipeline, at: 23) == Fixture.accepted())
        #expect(try Fixture.ledger(pipeline).windowStart == 23)
    }

    @Test("A refused call tells how long to wait: the same call succeeds that many ticks later, not one fewer")
    func retryAfterIsExactlyTheWait() throws {
        var pipeline = try Fixture.pipeline(packets: 1)
        try Fixture.go(&pipeline, at: 4)
        for tick in UInt64(5)...13 {
            var attempt = pipeline
            guard case .failure(.packetBudgetExceeded(_, let wait)) = try Fixture.go(&attempt, at: tick) else {
                Issue.record("tick \(tick) was not refused")
                continue
            }
            // The window opened at 4 and lasts 10 ticks, so every wait ends at tick 14.
            #expect(wait == 14 - tick)
            let lastTick = Refusal.packetBudgetExceeded(limit: 1, retryAfterTicks: 1)
            #expect(try Fixture.go(&attempt, at: tick + wait - 1) == .failure(lastTick))
            #expect(try Fixture.go(&attempt, at: tick + wait) == Fixture.accepted())
        }
    }

    @Test("A roll resets packets, bytes and malformed strikes together")
    func rollResetsEveryCounter() throws {
        var pipeline = try Fixture.pipeline()
        try Fixture.go(&pipeline, at: 0)
        Fixture.receive(&pipeline, Fixture.garbage, at: 1)
        Fixture.receive(&pipeline, Fixture.garbage, at: 2)
        let before = try Fixture.ledger(pipeline)
        #expect(before.packets == 3 && before.bytes == 36 && before.malformed == 2 && before.quarantinedAt == nil)
        #expect(try Fixture.go(&pipeline, at: 10) == Fixture.accepted())
        let after = try Fixture.ledger(pipeline)
        #expect(after.windowStart == 10 && after.packets == 1 && after.bytes == 12 && after.malformed == 0)
        // The fresh window tolerates two strikes again; the third quarantines.
        Fixture.receive(&pipeline, Fixture.garbage, at: 11)
        Fixture.receive(&pipeline, Fixture.garbage, at: 12)
        #expect(try Fixture.ledger(pipeline).quarantinedAt == nil)
        Fixture.receive(&pipeline, Fixture.garbage, at: 13)
        #expect(try Fixture.ledger(pipeline).quarantinedAt == 13)
    }

    // MARK: Malformed input and quarantine

    @Test("Each codec refusal is reported as malformed and charged one packet, its bytes and one strike")
    func malformedInputsAreChargedOnce() throws {
        var pipeline = try Fixture.pipeline(malformed: 3)
        let inputs: [([UInt8], OSC.CodecError)] = [
            (Fixture.garbage, .unrecognizedPacket), ([], .emptyPacket),
            ([1, 2, 3, 4, 5], .packetNotAligned(byteCount: 5))
        ]
        var bytes = 0
        for (index, (input, error)) in inputs.enumerated() {
            #expect(Fixture.receive(&pipeline, input, at: UInt64(index)) == .failure(.malformed(error)))
            bytes += input.count
            let ledger = try Fixture.ledger(pipeline)
            #expect(ledger.packets == index + 1 && ledger.bytes == bytes && ledger.malformed == index + 1)
        }
        #expect(try Fixture.ledger(pipeline).quarantinedAt == nil)
    }

    @Test("Strike N+1 quarantines at its own tick; the peer is refused until the cooldown has elapsed")
    func quarantineStartsAtTheStrikeAndEndsAtTheExactTick() throws {
        var pipeline = try Fixture.pipeline()
        let malformed = Refusal.malformed(.unrecognizedPacket)
        #expect(Fixture.receive(&pipeline, Fixture.garbage, at: 0) == .failure(malformed))
        #expect(Fixture.receive(&pipeline, Fixture.garbage, at: 1) == .failure(malformed))
        #expect(try Fixture.ledger(pipeline).quarantinedAt == nil)
        #expect(Fixture.receive(&pipeline, Fixture.garbage, at: 2) == .failure(malformed))
        #expect(try Fixture.ledger(pipeline).quarantinedAt == 2)
        for (tick, wait) in [(3, 19), (10, 12), (21, 1)] as [(UInt64, UInt64)] {
            let refusal = Refusal.peerQuarantined(retryAfterTicks: wait)
            #expect(try Fixture.go(&pipeline, at: tick) == .failure(refusal))
            #expect(Fixture.receive(&pipeline, Fixture.garbage, at: tick) == .failure(refusal))
        }
        let strikes = try Fixture.ledger(pipeline)
        #expect(strikes.packets == 3 && strikes.malformed == 3)
        #expect(try Fixture.go(&pipeline, at: 22) == Fixture.accepted())
        let released = try Fixture.ledger(pipeline)
        #expect(released.quarantinedAt == nil && released.windowStart == 22 && released.malformed == 0)
        #expect(released.packets == 1 && released.bytes == 12)
    }

    @Test("Tolerating no malformed input quarantines on the first strike")
    func malformedLimitZeroQuarantinesImmediately() throws {
        var pipeline = try Fixture.pipeline(malformed: 0)
        #expect(Fixture.receive(&pipeline, Fixture.garbage, at: 5) == .failure(.malformed(.unrecognizedPacket)))
        #expect(try Fixture.ledger(pipeline).quarantinedAt == 5)
        #expect(try Fixture.go(&pipeline, at: 24) == .failure(.peerQuarantined(retryAfterTicks: 1)))
        #expect(try Fixture.go(&pipeline, at: 25) == Fixture.accepted())
    }

    @Test("A valid packet the stage refuses is charged as a packet but is never a malformed strike")
    func notAdmittedIsChargedButNeverAStrike() throws {
        var pipeline = try Fixture.pipeline(malformed: 0)
        let unlisted = try Fixture.datagram(1, "/nope")
        let refusal = Refusal.notAdmitted(.disallowedAddress("/nope"))
        for tick in 0..<3 {
            #expect(Fixture.receive(&pipeline, unlisted, at: UInt64(tick)) == .failure(refusal))
        }
        let ledger = try Fixture.ledger(pipeline)
        #expect(ledger.packets == 3 && ledger.bytes == 48 && ledger.malformed == 0 && ledger.quarantinedAt == nil)
        #expect(try Fixture.go(&pipeline, at: 3) == Fixture.accepted())
        #expect(try Fixture.go(&pipeline, at: 4) == .failure(.packetBudgetExceeded(limit: 4, retryAfterTicks: 6)))
    }

    // MARK: The ledger on its own

    @Test("A strike beyond the tolerance quarantines at that tick; a later strike keeps the first tick")
    func ledgerQuarantinesOnceAndKeepsItsTick() throws {
        let budget = try Fixture.budget(malformed: 1)
        let first = OSC.PeerLedger.fresh(at: 5).chargingMalformed(at: 6, budget: budget)
        #expect(first.malformed == 1 && first.quarantinedAt == nil && first.lastActivity == 6)
        let second = first.chargingMalformed(at: 7, budget: budget)
        #expect(second.malformed == 2 && second.quarantinedAt == 7 && second.lastActivity == 7)
        #expect(second.chargingMalformed(at: 9, budget: budget) == second)
        // A strike never moves the last activity backwards.
        let early = OSC.PeerLedger.fresh(at: 9).chargingMalformed(at: 4, budget: budget)
        #expect(early.lastActivity == 9)
    }

    @Test("Quarantine covers exactly the cooldown, and a tick before it began")
    func ledgerQuarantineBoundaries() throws {
        let budget = try Fixture.budget(malformed: 0)
        let quarantined = OSC.PeerLedger.fresh(at: 0).chargingMalformed(at: 10, budget: budget)
        #expect(quarantined.quarantinedAt == 10)
        for (tick, expected) in [(9, true), (10, true), (29, true), (30, false), (31, false)] as [(UInt64, Bool)] {
            #expect(quarantined.isQuarantined(at: tick, budget: budget) == expected, "tick \(tick)")
        }
        let clean = OSC.PeerLedger.fresh(at: 0)
        #expect(!clean.isQuarantined(at: 0, budget: budget) && !clean.isQuarantined(at: .max, budget: budget))
    }

    @Test("A peer is idle once quiet for the idle span, unless it is quarantined or the tick is earlier")
    func ledgerIdleBoundaries() throws {
        let budget = try Fixture.budget(malformed: 0)
        let ledger = OSC.PeerLedger.fresh(at: 5)
        for (tick, expected) in [(4, false), (5, false), (14, false), (15, true), (16, true)] as [(UInt64, Bool)] {
            #expect(ledger.isIdle(at: tick, budget: budget, idleTicks: 10) == expected, "tick \(tick)")
        }
        let quarantined = ledger.chargingMalformed(at: 5, budget: budget)
        #expect(!quarantined.isIdle(at: 24, budget: budget, idleTicks: 10))
        #expect(quarantined.isIdle(at: 25, budget: budget, idleTicks: 10))
    }

    @Test("A chunk charges bytes but needs packet room; a frame charges one packet and no bytes")
    func ledgerChargesChunksAndFramesSeparately() throws {
        let budget = try Fixture.budget(packets: 2, bytes: 100)
        let ledger = OSC.PeerLedger.fresh(at: 0)
        let chunked = try ledger.admittingChunk(byteCount: 60, at: 0, budget: budget)
        #expect(chunked.packets == 0 && chunked.bytes == 60)
        let framed = try chunked.admittingFrame(at: 1, budget: budget)
        #expect(framed.packets == 1 && framed.bytes == 60 && framed.lastActivity == 1)
        let full = try framed.admittingFrame(at: 1, budget: budget)
        #expect(full.packets == 2)
        let packets = Refusal.packetBudgetExceeded(limit: 2, retryAfterTicks: 9)
        #expect(throws: packets) { try full.admittingChunk(byteCount: 0, at: 1, budget: budget) }
        #expect(throws: packets) { try full.admittingFrame(at: 1, budget: budget) }
        #expect(throws: packets) { try full.admittingDatagram(byteCount: 0, at: 1, budget: budget) }
        // With every byte used a frame still fits (it carries no bytes), a datagram does not.
        let drained = try ledger.admittingChunk(byteCount: 100, at: 0, budget: budget)
        #expect(try drained.admittingFrame(at: 0, budget: budget).packets == 1)
        #expect(throws: Refusal.byteBudgetExceeded(limit: 100, retryAfterTicks: 10)) {
            try drained.admittingDatagram(byteCount: 1, at: 0, budget: budget)
        }
        let datagram = try ledger.admittingDatagram(byteCount: 40, at: 2, budget: budget)
        #expect(datagram.packets == 1 && datagram.bytes == 40)
    }

    @Test("A ledger refuses a tick before its last activity; an equal tick is fine")
    func ledgerRefusesRegressedTicks() throws {
        let budget = try Fixture.budget()
        let ledger = try OSC.PeerLedger.fresh(at: 0).admittingDatagram(byteCount: 12, at: 5, budget: budget)
        #expect(throws: Refusal.tickRegressed(previous: 5, now: 4)) {
            try ledger.admittingDatagram(byteCount: 12, at: 4, budget: budget)
        }
        #expect(try ledger.admittingDatagram(byteCount: 12, at: 5, budget: budget).packets == 2)
    }

    @Test("A new peer's ledger is an empty window that starts, and was last active, at its own tick")
    func freshLedgerIsAnEmptyWindowAtItsTick() {
        for tick in [0, 7, .max] as [UInt64] {
            let ledger = OSC.PeerLedger.fresh(at: tick)
            #expect(ledger.windowStart == tick && ledger.lastActivity == tick, "tick \(tick)")
            #expect(ledger.packets == 0 && ledger.bytes == 0 && ledger.malformed == 0, "tick \(tick)")
            #expect(ledger.quarantinedAt == nil, "tick \(tick)")
        }
    }

    @Test("A tick before a ledger's last activity is a typed regression, or quarantined and not idle")
    func ledgerHandlesTicksBeforeItsLastActivity() throws {
        let budget = try Fixture.budget(malformed: 0)
        let jailed = OSC.PeerLedger.fresh(at: 2).chargingMalformed(at: 10, budget: budget)
        #expect(jailed.quarantinedAt == 10 && jailed.lastActivity == 10 && jailed.windowStart == 2)
        for tick in [0, 2, 9] as [UInt64] {
            #expect(jailed.isQuarantined(at: tick, budget: budget), "tick \(tick)")
            #expect(!jailed.isIdle(at: tick, budget: budget, idleTicks: 1), "tick \(tick)")
        }
        // The regression names the last activity (8), not the start of the window (2).
        let active = try OSC.PeerLedger.fresh(at: 2).admittingDatagram(byteCount: 1, at: 8, budget: budget)
        for tick in [2, 5, 7] as [UInt64] {
            #expect(throws: Refusal.tickRegressed(previous: 8, now: tick)) {
                try active.admittingDatagram(byteCount: 1, at: tick, budget: budget)
            }
        }
        #expect(try active.admittingDatagram(byteCount: 1, at: 8, budget: budget).packets == 2)
    }

    @Test("Extreme ticks and sizes never overflow")
    func ledgerArithmeticNeverOverflows() throws {
        // First the hint on a small window, where nothing can overflow. A wrong hint ends the test here, before
        // the extreme calls below, which would trap rather than fail.
        let small = try Fixture.budget(packets: 1)
        let used = try OSC.PeerLedger.fresh(at: 0).admittingDatagram(byteCount: 1, at: 0, budget: small)
        var hint: Refusal?
        do throws(Refusal) {
            _ = try used.admittingDatagram(byteCount: 1, at: 0, budget: small)
        } catch {
            hint = error
        }
        let expected = Refusal.packetBudgetExceeded(limit: 1, retryAfterTicks: 10)
        #expect(hint == expected)
        guard hint == expected else { return }
        let forever = try Fixture.budget(window: .max, cooldown: .max)
        let ledger = OSC.PeerLedger.fresh(at: 0)
        let late = try ledger.admittingDatagram(byteCount: 1, at: .max - 1, budget: forever)
        #expect(late.windowStart == 0 && late.packets == 1)
        #expect(throws: Refusal.byteBudgetExceeded(limit: 1_024, retryAfterTicks: .max)) {
            try ledger.admittingDatagram(byteCount: .max, at: 0, budget: forever)
        }
        let rolled = try late.admittingDatagram(byteCount: 1, at: .max, budget: forever)
        #expect(rolled.windowStart == .max && rolled.packets == 1)
        // A window that opened at the wrong tick would make the calls below trap rather than fail: stop here.
        guard rolled.windowStart == .max else { return }
        let strict = try Fixture.budget(malformed: 0, cooldown: .max)
        let jailed = ledger.chargingMalformed(at: 0, budget: strict)
        #expect(throws: Refusal.peerQuarantined(retryAfterTicks: 1)) {
            try jailed.admittingDatagram(byteCount: 1, at: .max - 1, budget: strict)
        }
        #expect(try jailed.admittingDatagram(byteCount: 1, at: .max, budget: strict).packets == 1)
        let widest = try Fixture.budget(packets: 65_536, bytes: 1 << 30)
        let full = try ledger.admittingDatagram(byteCount: 1 << 30, at: 0, budget: widest)
        #expect(full.bytes == 1 << 30)
        #expect(throws: Refusal.byteBudgetExceeded(limit: 1 << 30, retryAfterTicks: 10)) {
            try full.admittingDatagram(byteCount: 1, at: 0, budget: widest)
        }
    }

    // MARK: Peer table and expiry

    @Test("The table admits N peers and refuses peer N+1 without evicting anyone")
    func peerTableAdmitsNAndRefusesNPlusOne() throws {
        var pipeline = try Fixture.pipeline(peers: 2)
        #expect(try Fixture.go(&pipeline, from: Fixture.alpha, at: 0) == Fixture.accepted())
        #expect(try Fixture.go(&pipeline, from: Fixture.bravo, at: 0) == Fixture.accepted())
        let full = Refusal.peerTableFull(limit: 2)
        #expect(try Fixture.go(&pipeline, from: Fixture.charlie, at: 1) == .failure(full))
        #expect(Fixture.receive(&pipeline, Fixture.garbage, from: Fixture.charlie, at: 5) == .failure(full))
        #expect(pipeline.peerKeys == [Fixture.alpha, Fixture.bravo] && pipeline.ledger(for: Fixture.charlie) == nil)
        #expect(try Fixture.go(&pipeline, from: Fixture.bravo, at: 6) == Fixture.accepted())
        #expect(try Fixture.ledger(pipeline, Fixture.alpha).packets == 1)
        #expect(try Fixture.ledger(pipeline, Fixture.bravo).packets == 2)
    }

    @Test("The table holds exactly the largest allowed peer count and refuses one more")
    func peerTableAtItsCeiling() throws {
        var pipeline = try Fixture.pipeline(peers: OSC.EndpointPolicy.peerLimit)
        for raw in 1...UInt64(OSC.EndpointPolicy.peerLimit) {
            #expect(try Fixture.go(&pipeline, from: OSC.PeerKey(rawValue: raw), at: 0) == Fixture.accepted())
        }
        #expect(pipeline.peerCount == 256)
        let overflow = OSC.PeerKey(rawValue: 257)
        #expect(try Fixture.go(&pipeline, from: overflow, at: 0) == .failure(.peerTableFull(limit: 256)))
        #expect(pipeline.peerCount == 256 && pipeline.ledger(for: overflow) == nil)
    }

    @Test("Expire frees exactly the peers idle for idleTicks and reports them in ascending order")
    func expireFreesOnlyIdlePeers() throws {
        var pipeline = try Fixture.pipeline()
        try Fixture.go(&pipeline, from: Fixture.charlie, at: 0)
        try Fixture.go(&pipeline, from: Fixture.alpha, at: 0)
        try Fixture.go(&pipeline, from: Fixture.bravo, at: 5)
        #expect(Fixture.expire(&pipeline, at: 9) == .success([]))
        #expect(pipeline.peerKeys == [Fixture.alpha, Fixture.bravo, Fixture.charlie] && pipeline.latestTick == 9)
        #expect(Fixture.expire(&pipeline, at: 10) == .success([Fixture.alpha, Fixture.charlie]))
        #expect(pipeline.peerKeys == [Fixture.bravo] && pipeline.latestTick == 10)
        #expect(Fixture.expire(&pipeline, at: 15) == .success([Fixture.bravo]))
        #expect(pipeline.peerCount == 0)
        #expect(try Fixture.go(&pipeline, at: 15) == Fixture.accepted())
        let returning = try Fixture.ledger(pipeline)
        #expect(returning.windowStart == 15 && returning.packets == 1)
    }

    @Test("A peer that is still active is never expired, and a freed slot admits a new peer")
    func expireKeepsActivePeersAndFreesSlots() throws {
        var pipeline = try Fixture.pipeline(peers: 1)
        try Fixture.go(&pipeline, at: 0)
        try Fixture.go(&pipeline, at: 9)
        #expect(try Fixture.go(&pipeline, from: Fixture.bravo, at: 9) == .failure(.peerTableFull(limit: 1)))
        #expect(Fixture.expire(&pipeline, at: 10) == .success([]))
        #expect(Fixture.expire(&pipeline, at: 19) == .success([Fixture.alpha]))
        #expect(try Fixture.go(&pipeline, from: Fixture.bravo, at: 19) == Fixture.accepted())
    }

    @Test("A quarantined peer stays in the table until its cooldown has elapsed")
    func expireKeepsQuarantinedPeers() throws {
        var pipeline = try Fixture.pipeline(malformed: 0)
        Fixture.receive(&pipeline, Fixture.garbage, at: 0)
        try Fixture.go(&pipeline, from: Fixture.bravo, at: 0)
        #expect(Fixture.expire(&pipeline, at: 19) == .success([Fixture.bravo]))
        #expect(pipeline.peerKeys == [Fixture.alpha])
        #expect(try Fixture.go(&pipeline, at: 19) == .failure(.peerQuarantined(retryAfterTicks: 1)))
        #expect(Fixture.expire(&pipeline, at: 20) == .success([Fixture.alpha]))
    }

    // MARK: Isolation

    @Test("A flooding peer cannot starve another peer, and its refused attempts change nothing")
    func floodingPeerIsIsolated() throws {
        var flood = try Fixture.pipeline()
        var five = flood
        for value in 0..<100 { try Fixture.go(&flood, Int32(value), at: 3) }
        for value in 0..<5 { try Fixture.go(&five, Int32(value), at: 3) }
        #expect(flood == five)
        #expect(try Fixture.go(&flood, 9, from: Fixture.bravo, at: 3) == Fixture.accepted(9))
        let other = try Fixture.ledger(flood, Fixture.bravo)
        #expect(other.windowStart == 3 && other.packets == 1 && other.bytes == 12)
        #expect(try Fixture.ledger(flood).packets == 4)

        var noisy = try Fixture.pipeline()
        for _ in 0..<50 { Fixture.receive(&noisy, Fixture.garbage, at: 1) }
        let strikes = try Fixture.ledger(noisy)
        #expect(strikes.packets == 3 && strikes.bytes == 36 && strikes.malformed == 3 && strikes.quarantinedAt == 1)
        #expect(try Fixture.go(&noisy, from: Fixture.bravo, at: 1) == Fixture.accepted())
    }

    // MARK: The charge oracle

    @Test("The test oracle says a peer was charged for exactly the two refusals that follow the charge")
    func chargeOracleClassifiesEveryRefusal() {
        let charged: [Refusal] = [.malformed(.unrecognizedPacket), .notAdmitted(.disallowedAddress("/nope"))]
        let uncharged: [Refusal] = [
            .endpointDisabled, .wrongTransport(expected: .datagram), .tickRegressed(previous: 1, now: 0),
            .chunkTooLarge(byteCount: 69, limit: 68), .datagramTooLarge(byteCount: 13, limit: 12),
            .peerTableFull(limit: 1), .peerQuarantined(retryAfterTicks: 1),
            .packetBudgetExceeded(limit: 1, retryAfterTicks: 1), .byteBudgetExceeded(limit: 1, retryAfterTicks: 1)
        ]
        // Eleven refusals in all. The fixture's switch has no `default`, so a twelfth cannot compile unclassified.
        #expect(charged.count + uncharged.count == 11)
        for refusal in charged { #expect(Fixture.chargesPeer(refusal), "\(refusal)") }
        for refusal in uncharged { #expect(!Fixture.chargesPeer(refusal), "\(refusal)") }
    }
}
