import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Seeded scripts for the bounded-intake properties. A script is a pure function of its seed, so a failure names
/// the seed that reproduces it. Ticks are plain integers; nothing here reads a clock or a device.
extension OSCTransportFixture {
    /// SplitMix64, a small deterministic generator.
    struct SplitMix: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    /// One call: `bytes` from `key` at `tick`, sent as a datagram or, on a stream endpoint, as a chunk.
    struct Step: Equatable {
        let tick: UInt64
        let key: OSC.PeerKey
        let bytes: [UInt8]
    }

    enum Observation: Equatable {
        case datagram(OSC.IntakeResult)
        case chunk(OSC.ChunkOutcome)
    }

    /// What a replay saw, per peer and in that peer's own order, and how many peers expiry freed.
    struct Replay: Equatable {
        var seen: [OSC.PeerKey: [Observation]] = [:]
        var freed = 0
    }

    static let scriptPeers = [alpha, bravo, charlie]
    static let delta = OSC.PeerKey(rawValue: 4)
    static let echo = OSC.PeerKey(rawValue: 5)
    static let foxtrot = OSC.PeerKey(rawValue: 6)
    /// Six sources for the four-slot table of `scriptPipeline`: the last two never find a free slot.
    static let crowd = [alpha, bravo, charlie, delta, echo, foxtrot]

    /// A tight pipeline (64 byte packets, 3 packets and 64 bytes per 5 tick window; a stream's allowance is 68, as
    /// it must hold one whole chunk) so that random scripts reach every budget, quarantine, release and expiry path.
    static func scriptPipeline(_ transport: OSC.EndpointTransport) throws -> OSC.IntakePipeline {
        try pipeline(
            transport, packets: 3, bytes: transport.framing == nil ? 64 : 68, malformed: 2, window: 5, cooldown: 7,
            peers: 4, idle: 5, packetBytes: 64
        )
    }

    // MARK: Generating scripts

    /// Valid, listed, unlisted, scheduled, malformed, empty, nearly oversize and oversize datagrams. The 60 byte
    /// one nearly uses the 64 byte allowance, so whatever follows it in the window is over the byte budget.
    static func datagramPayload(_ generator: inout SplitMix) throws -> [UInt8] {
        let roll = Int.random(in: 0..<30, using: &generator)
        let value = Int32.random(in: 0..<1_000, using: &generator)
        switch roll {
        case 0...13: return try datagram(value)
        case 14...17: return try datagram(value, "/mixer/3/fader")
        case 18...20: return try datagram(value, "/nope")
        case 21...24: return garbage
        case 25...26: return []
        case 27: return [UInt8](repeating: 0x2F, count: 65)
        case 28: return [UInt8](repeating: 0x2F, count: 60)
        default: return try encode(bundle(OSC.TimeTag(seconds: 1, fraction: 2), [.message(message(value))]))
        }
    }

    /// Whole frames, garbage frames, fragments, noise and, on a length prefix, the occasional fatal header.
    static func chunkPayload(_ framing: OSC.StreamFraming, _ generator: inout SplitMix) throws -> [UInt8] {
        let roll = Int.random(in: 0..<32, using: &generator)
        let value = Int32.random(in: 0..<1_000, using: &generator)
        let slip = framing == .slip
        let framed = try frame(datagram(value), framing)
        switch roll {
        case 0...11: return framed
        case 12...14: return try frame(datagram(value, "/mixer/3/fader"), framing)
        case 15...17: return try frame(garbage, framing)
        case 18...19: return try frame(blobDatagram(4 * Int.random(in: 0...12, using: &generator)), framing)
        case 20...21: return []
        case 22...23: return slip ? [0xC0] : [0]
        case 24...27: return slip ? fragment(of: framed, &generator) : framed + framed
        case 28...30: return slip ? noise(&generator) : framed
        default: return slip ? [0xDB, UInt8.random(in: 0...255, using: &generator)] : [0, 0, 0, 65]
        }
    }

    /// A random suffix of `framed`: the tail of a frame whose start never arrived.
    static func fragment(of framed: [UInt8], _ generator: inout SplitMix) -> [UInt8] {
        Array(framed.dropFirst(Int.random(in: 1..<framed.count, using: &generator)))
    }

    /// 1 through 70 random bytes; the chunk limit of the script pipeline is 68.
    static func noise(_ generator: inout SplitMix) -> [UInt8] {
        (0..<Int.random(in: 1...70, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// `ticks` rounds. In each, every one of `peers` sends up to three payloads, in its own order.
    static func rounds(
        _ transport: OSC.EndpointTransport, ticks: Int, _ generator: inout SplitMix,
        peers: [OSC.PeerKey] = scriptPeers
    ) throws -> [[Step]] {
        var rounds: [[Step]] = []
        for tick in 0..<ticks {
            var round: [Step] = []
            for key in peers {
                for _ in 0..<Int.random(in: 0...3, using: &generator) {
                    let bytes: [UInt8]
                    if let framing = transport.framing {
                        bytes = try chunkPayload(framing, &generator)
                    } else {
                        bytes = try datagramPayload(&generator)
                    }
                    round.append(Step(tick: UInt64(tick), key: key, bytes: bytes))
                }
            }
            rounds.append(round)
        }
        return rounds
    }

    /// `rounds` for the six `crowd` sources. Round 0 is replaced by one valid call from each of the first four, so
    /// those four hold the table of `scriptPipeline` from tick 0, and the other two meet it full whatever the
    /// interleaving: their first contact is always refused as `peerTableFull`.
    static func crowdedRounds(
        _ transport: OSC.EndpointTransport, ticks: Int, _ generator: inout SplitMix
    ) throws -> [[Step]] {
        var scripted = try rounds(transport, ticks: ticks, &generator, peers: crowd)
        guard !scripted.isEmpty else { return scripted }
        let valid: [UInt8]
        if let framing = transport.framing {
            valid = try frame(datagram(1), framing)
        } else {
            valid = try datagram(1)
        }
        scripted[0] = crowd.prefix(4).map { Step(tick: 0, key: $0, bytes: valid) }
        return scripted
    }

    /// A random merge of one tick's calls that keeps each peer's own order.
    static func interleaved(_ round: [Step], _ generator: inout SplitMix) -> [Step] {
        var queues = Dictionary(grouping: round, by: \.key).mapValues { Array($0.reversed()) }
        var merged: [Step] = []
        while true {
            let live = queues.filter { !$0.value.isEmpty }.keys.sorted()
            guard !live.isEmpty else { return merged }
            let pick = live[Int.random(in: 0..<live.count, using: &generator)]
            if let step = queues[pick]?.popLast() { merged.append(step) }
        }
    }

    // MARK: Replaying scripts

    /// Replays `steps` in order. With `expiring`, idle peers are expired at the start of every new tick, and
    /// `check` runs after every call.
    static func run(
        _ steps: [Step], on pipeline: inout OSC.IntakePipeline, expiring: Bool = false,
        after check: (OSC.IntakePipeline) -> Void = { _ in }
    ) -> Replay {
        var replay = Replay()
        var previous: UInt64?
        let stream = pipeline.endpoint.policy?.transport.framing != nil
        for step in steps {
            if expiring, step.tick != previous, case .success(let freed) = expire(&pipeline, at: step.tick) {
                replay.freed += freed.count
                check(pipeline)
            }
            previous = step.tick
            let observation: Observation = stream
                ? .chunk(chunk(&pipeline, step.bytes, from: step.key, at: step.tick))
                : .datagram(receive(&pipeline, step.bytes, from: step.key, at: step.tick))
            replay.seen[step.key, default: []].append(observation)
            check(pipeline)
        }
        return replay
    }

    /// The invariants that hold after every call; returns a description of each one that does not.
    static func violations(_ pipeline: OSC.IntakePipeline, after previous: UInt64) -> [String] {
        guard let policy = pipeline.endpoint.policy else { return ["the endpoint is disabled"] }
        let budget = policy.budget
        let latest = pipeline.latestTick ?? 0
        var broken: [String] = []
        func require(_ holds: Bool, _ name: String) { if !holds { broken.append(name) } }
        require(latest >= previous, "time went backwards")
        require(pipeline.peerCount <= policy.maximumPeers, "the peer table is above its limit")
        require(pipeline.bufferedByteCount <= policy.bufferedByteBound, "held bytes are above the bound")
        for key in pipeline.peerKeys {
            guard let ledger = pipeline.ledger(for: key) else { broken.append("a peer has no ledger"); continue }
            require(ledger.packets <= budget.maximumPackets, "packets are above their allowance")
            require(ledger.bytes <= budget.maximumBytes, "bytes are above their allowance")
            require(ledger.malformed <= budget.maximumMalformed + 1, "strikes are above the allowance plus one")
            require(ledger.windowStart <= ledger.lastActivity, "a window began after its last activity")
            require(ledger.lastActivity <= latest, "activity is later than the latest tick")
            let struck = ledger.malformed > budget.maximumMalformed
            require((ledger.quarantinedAt != nil) == struck, "quarantine disagrees with strikes")
            let framed = pipeline.framerState(for: key) != nil
            require(framed == (policy.transport.framing != nil), "framers disagree with the transport")
        }
        return broken
    }

    /// The kind of each result a call produced, such as `success` or `packetBudgetExceeded`.
    static func kinds(_ observation: Observation) -> Set<String> {
        func name(_ result: OSC.IntakeResult) -> String {
            guard case .failure(let refusal) = result else { return "success" }
            return String(String(describing: refusal).prefix { $0 != "(" })
        }
        switch observation {
        case .datagram(let result): return [name(result)]
        case .chunk(.refused(let refusal)): return [name(.failure(refusal))]
        case .chunk(.consumed(let results)): return Set(results.map(name))
        }
    }

    // MARK: Splitting a stream

    /// At most 68 bytes of one stream: framed messages and, on SLIP, escapes and long runs without an END.
    static func wire(_ framing: OSC.StreamFraming, _ generator: inout SplitMix) throws -> [UInt8] {
        var bytes: [UInt8] = []
        while bytes.count < 68 {
            let slip = framing == .slip
            switch Int.random(in: 0..<8, using: &generator) {
            case 0...2: bytes += try frame(datagram(Int32.random(in: 0..<100, using: &generator)), framing)
            case 3: bytes += try frame(datagram(1, "/mixer/3/fader"), framing)
            case 4: bytes += try frame(garbage, framing)
            case 5 where slip: bytes += [0xDB, UInt8.random(in: 0...255, using: &generator)]
            case 6 where slip: bytes += [UInt8](repeating: 0x41, count: Int.random(in: 60...70, using: &generator))
            default: bytes += try frame(blobDatagram(4 * Int.random(in: 0...12, using: &generator)), framing)
            }
        }
        return Array(bytes.prefix(68))
    }

    /// Everything one delivery of a stream produced.
    struct Delivery: Equatable {
        var results: [OSC.IntakeResult]
        var ledger: OSC.PeerLedger?
        var state: OSC.FramerState?
        var held: Int
    }

    /// Delivers `bytes` to a pipeline with generous budgets, in pieces ending at each of `cuts` and then the end.
    static func deliver(_ bytes: [UInt8], cuts: [Int], _ framing: OSC.StreamFraming) throws -> Delivery {
        var intake = try pipeline(
            .stream(framing), packets: 1_000, bytes: 1 << 20, malformed: 1_024, packetBytes: 64
        )
        var results: [OSC.IntakeResult] = []
        var start = 0
        for end in cuts + [bytes.count] {
            results += Self.results(chunk(&intake, Array(bytes[start..<end]), at: 0))
            start = end
        }
        return Delivery(
            results: results, ledger: intake.ledger(for: alpha), state: intake.framerState(for: alpha),
            held: intake.bufferedByteCount
        )
    }
}

/// Properties over seeded scripts (#89, O2b).
extension OSCTransportTests {
    // MARK: Scripts

    @Test("What each peer sees, and the pipeline it leaves behind, never depend on how the peers are interleaved")
    func interleavingNeverChangesWhatEachPeerSees() throws {
        let transports: [OSC.EndpointTransport] = [.datagram, .stream(.slip), .stream(.lengthPrefixed)]
        var kinds: Set<String> = []
        for transport in transports {
            for seed in UInt64(0)..<12 {
                var generator = Fixture.SplitMix(seed: seed)
                let rounds = try Fixture.crowdedRounds(transport, ticks: 24, &generator)
                var baseline = try Fixture.scriptPipeline(transport)
                let expected = Fixture.run(rounds.flatMap { $0 }, on: &baseline)
                kinds.formUnion(expected.seen.values.joined().flatMap(Fixture.kinds))
                var replayed = try Fixture.scriptPipeline(transport)
                #expect(Fixture.run(rounds.flatMap { $0 }, on: &replayed) == expected, "replay \(transport) \(seed)")
                for variant in 0..<3 {
                    var other = try Fixture.scriptPipeline(transport)
                    let steps = rounds.flatMap { Fixture.interleaved($0, &generator) }
                    #expect(Fixture.run(steps, on: &other) == expected, "\(transport) seed \(seed) variant \(variant)")
                    #expect(other == baseline, "\(transport) seed \(seed) variant \(variant)")
                }
            }
        }
        let reached: Set<String> = [
            "success", "malformed", "notAdmitted", "packetBudgetExceeded", "byteBudgetExceeded", "peerQuarantined",
            "chunkTooLarge", "datagramTooLarge", "peerTableFull"
        ]
        #expect(kinds.isSuperset(of: reached), "never reached \(reached.subtracting(kinds).sorted())")
    }

    @Test("Expiring idle peers between calls never changes what a datagram peer sees")
    func expiryIsTransparentToDatagramPeers() throws {
        var freed = 0
        for seed in UInt64(0)..<16 {
            var generator = Fixture.SplitMix(seed: seed &+ 500)
            let steps = try Fixture.rounds(.datagram, ticks: 30, &generator).flatMap { $0 }
            var plain = try Fixture.scriptPipeline(.datagram)
            var expiring = try Fixture.scriptPipeline(.datagram)
            let expected = Fixture.run(steps, on: &plain)
            let replay = Fixture.run(steps, on: &expiring, expiring: true)
            #expect(replay.seen == expected.seen, "seed \(seed)")
            freed += replay.freed
        }
        #expect(freed > 0, "no script ever freed a peer")
    }

    @Test("Whatever arrives, every ledger, the peer table and the held bytes stay inside their bounds")
    func randomScriptsStayInsideTheirBounds() throws {
        let transports: [OSC.EndpointTransport] = [.datagram, .stream(.slip), .stream(.lengthPrefixed)]
        for transport in transports {
            for seed in UInt64(0)..<16 {
                var generator = Fixture.SplitMix(seed: seed &+ 1_000)
                let steps = try Fixture.crowdedRounds(transport, ticks: 30, &generator).flatMap { $0 }
                var pipeline = try Fixture.scriptPipeline(transport)
                var previous: UInt64 = 0
                _ = Fixture.run(steps, on: &pipeline, expiring: seed.isMultiple(of: 2)) { state in
                    #expect(Fixture.violations(state, after: previous).isEmpty, "\(transport) seed \(seed)")
                    previous = state.latestTick ?? previous
                }
            }
        }
    }

    @Test("A stream's results do not depend on where its chunks are cut", arguments: Fixture.framings)
    func splitDeliveryDoesNotChangeResults(_ framing: OSC.StreamFraming) throws {
        for seed in UInt64(0)..<16 {
            var generator = Fixture.SplitMix(seed: seed &+ 2_000)
            let bytes = try Fixture.wire(framing, &generator)
            #expect(bytes.count == 68)
            let whole = try Fixture.deliver(bytes, cuts: [], framing)
            var cuts: [[Int]] = (1..<bytes.count).map { [$0] }
            cuts.append(Array(1..<bytes.count))
            for _ in 0..<4 {
                let random = (0..<8).map { _ in Int.random(in: 1..<bytes.count, using: &generator) }
                cuts.append(Set(random).sorted())
            }
            for cut in cuts {
                #expect(try Fixture.deliver(bytes, cuts: cut, framing) == whole, "\(framing) seed \(seed) cuts \(cut)")
            }
        }
    }
}
