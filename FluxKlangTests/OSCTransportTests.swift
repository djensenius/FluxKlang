import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared fixture for the OSC bounded-intake suites (#89, O2b). Everything is a value: ticks are plain integers,
/// and no test touches a clock, socket, MIDI, OSC or audio device.
enum OSCTransportFixture {
    typealias OSC = OpenSoundControl
    typealias Refusal = OpenSoundControl.IntakeRefusal
    typealias Config = OpenSoundControl.EndpointRefusal

    static let alpha = OSC.PeerKey(rawValue: 1)
    static let bravo = OSC.PeerKey(rawValue: 2)
    static let charlie = OSC.PeerKey(rawValue: 3)
    /// Twelve bytes that start with neither `/` nor `#`: the decoder refuses them as `unrecognizedPacket`.
    static let garbage = [UInt8](repeating: 0xFF, count: 12)
    /// The size of `datagram()`: the `/go` address and one int32 argument.
    static let goBytes = 12

    /// A count knob and its inclusive documented range.
    struct CountBound: Sendable {
        let knob: OSC.EndpointKnob
        let range: ClosedRange<Int>
    }

    static let countBounds = [
        CountBound(knob: .peers, range: 1...256), CountBound(knob: .packets, range: 1...65_536),
        CountBound(knob: .bytes, range: 1...(1 << 30)), CountBound(knob: .malformed, range: 0...1_024),
        CountBound(knob: .packetBytes, range: 1...65_536), CountBound(knob: .bundleDepth, range: 1...64)
    ]

    // MARK: Configuration

    static func allowList() throws -> OSC.AllowList {
        try OSC.AllowList(["/go", "/mixer/*/fader", "/fx/[1-4]/on"].map { try OSC.AddressPattern($0) })
    }

    static func budget(
        window: UInt64 = 10, packets: Int = 4, bytes: Int = 1_024, malformed: Int = 2, cooldown: UInt64 = 20
    ) throws -> OSC.IntakeBudget {
        try OSC.IntakeBudget(
            windowTicks: window, maximumPackets: packets, maximumBytes: bytes, maximumMalformed: malformed,
            cooldownTicks: cooldown
        )
    }

    static func policy(
        _ transport: OSC.EndpointTransport = .datagram, budget: OSC.IntakeBudget? = nil, peers: Int = 4,
        idle: UInt64 = 10, packetBytes: Int = 1_024, depth: Int = 8
    ) throws -> OSC.EndpointPolicy {
        try OSC.EndpointPolicy(
            transport: transport, allowList: allowList(), budget: budget ?? Self.budget(), maximumPeers: peers,
            idleTicks: idle, maximumPacketBytes: packetBytes, maximumBundleDepth: depth
        )
    }

    /// An enabled pipeline. The defaults: 4 packets, 1 024 bytes and 2 tolerated malformed inputs per 10 tick
    /// window, a 20 tick cooldown, 4 peers, idle expiry after 10 ticks and 1 024 byte packets.
    static func pipeline(
        _ transport: OSC.EndpointTransport = .datagram, packets: Int = 4, bytes: Int = 1_024, malformed: Int = 2,
        window: UInt64 = 10, cooldown: UInt64 = 20, peers: Int = 4, idle: UInt64 = 10, packetBytes: Int = 1_024,
        depth: Int = 8
    ) throws -> OSC.IntakePipeline {
        var pipeline = OSC.IntakePipeline()
        let allowance = try budget(
            window: window, packets: packets, bytes: bytes, malformed: malformed, cooldown: cooldown
        )
        try pipeline.enable(policy(
            transport, budget: allowance, peers: peers, idle: idle, packetBytes: packetBytes, depth: depth
        ))
        return pipeline
    }

    /// Builds a policy or budget whose only non-default value is `value` for `knob`; throws its refusal.
    static func build(_ knob: OSC.EndpointKnob, _ value: Int) throws {
        switch knob {
        case .peers: _ = try policy(peers: value)
        case .packets: _ = try budget(packets: value)
        case .bytes: _ = try budget(bytes: value)
        case .malformed: _ = try budget(malformed: value)
        case .packetBytes: _ = try policy(budget: budget(bytes: Swift.max(value, 1)), packetBytes: value)
        case .bundleDepth: _ = try policy(depth: value)
        case .window, .cooldown, .idle: Issue.record("\(knob) is a tick knob, not a count")
        }
    }

    // MARK: Packets

    static func message(_ value: Int32 = 0, _ address: String = "/go") throws -> OSC.Message {
        OSC.Message(address: try OSC.AddressPattern(address), arguments: [.int32(value)])
    }

    /// The encoded message: 12 bytes for `/go`, 24 for `/mixer/3/fader`, 16 for `/nope`.
    static func datagram(_ value: Int32 = 0, _ address: String = "/go") throws -> [UInt8] {
        try OSC.Encoder().encode(message(value, address))
    }

    /// What a valid, listed datagram yields: one batch holding its message.
    static func accepted(_ value: Int32 = 0, _ address: String = "/go") throws -> OSC.IntakeResult {
        .success([[try message(value, address)]])
    }

    static func bundle(_ timeTag: OSC.TimeTag = .immediate, _ elements: [OSC.Packet]) -> OSC.Packet {
        .bundle(OSC.Bundle(timeTag: timeTag, elements: elements))
    }

    /// `levels` immediate bundles nested around one `/go` message: a packet of bundle depth `levels`.
    static func nested(_ levels: Int, _ value: Int32 = 1) throws -> OSC.Packet {
        var packet = OSC.Packet.message(try message(value))
        for _ in 0..<levels { packet = bundle(.immediate, [packet]) }
        return packet
    }

    static func encode(_ packet: OSC.Packet, depth: Int = 8) throws -> [UInt8] {
        try OSC.Encoder(limits: OSC.Limits(maximumBundleDepth: depth)).encode(packet)
    }

    // MARK: Checked calls

    /// Whether a refusal came after the peer was charged for the input: only `malformed` and `notAdmitted`.
    /// The switch has no `default` on purpose: a new refusal must be classified here before the tests compile.
    static func chargesPeer(_ refusal: Refusal) -> Bool {
        switch refusal {
        case .malformed, .notAdmitted: true
        case .endpointDisabled, .wrongTransport, .tickRegressed, .chunkTooLarge, .datagramTooLarge,
             .peerTableFull, .peerQuarantined, .packetBudgetExceeded, .byteBudgetExceeded: false
        }
    }

    /// Receives one datagram; a gate refusal must leave the pipeline equal to its value before the call.
    @discardableResult
    static func receive(
        _ pipeline: inout OSC.IntakePipeline, _ bytes: [UInt8], from key: OSC.PeerKey = alpha, at now: UInt64,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> OSC.IntakeResult {
        let before = pipeline
        let result = pipeline.receive(datagram: bytes, from: key, now: now)
        if case .failure(let refusal) = result, !chargesPeer(refusal) {
            #expect(pipeline == before, "\(refusal) changed the pipeline", sourceLocation: sourceLocation)
        }
        return result
    }

    /// Receives a `/go` datagram carrying `value` (see `receive`).
    @discardableResult
    static func go(
        _ pipeline: inout OSC.IntakePipeline, _ value: Int32 = 0, from key: OSC.PeerKey = alpha, at now: UInt64,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> OSC.IntakeResult {
        receive(&pipeline, try datagram(value), from: key, at: now, sourceLocation: sourceLocation)
    }

    /// Receives one stream chunk; a gate refusal must leave the pipeline equal to its value before the call.
    @discardableResult
    static func chunk(
        _ pipeline: inout OSC.IntakePipeline, _ bytes: [UInt8], from key: OSC.PeerKey = alpha, at now: UInt64,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> OSC.ChunkOutcome {
        let before = pipeline
        let outcome = pipeline.receive(chunk: bytes, from: key, now: now)
        if case .refused(let refusal) = outcome {
            #expect(pipeline == before, "\(refusal) changed the pipeline", sourceLocation: sourceLocation)
        }
        return outcome
    }

    /// Expires idle peers; a refusal must leave the pipeline equal to its value before the call.
    @discardableResult
    static func expire(
        _ pipeline: inout OSC.IntakePipeline, at now: UInt64, sourceLocation: SourceLocation = #_sourceLocation
    ) -> Result<[OSC.PeerKey], Refusal> {
        let before = pipeline
        do throws(Refusal) {
            return .success(try pipeline.expire(now: now))
        } catch {
            #expect(pipeline == before, "\(error) changed the pipeline", sourceLocation: sourceLocation)
            return .failure(error)
        }
    }

    /// Enables a policy and returns the refusal, if any, after checking a refusal changed nothing.
    @discardableResult
    static func enable(
        _ pipeline: inout OSC.IntakePipeline, _ policy: OSC.EndpointPolicy,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Config? {
        let before = pipeline
        do throws(Config) {
            try pipeline.enable(policy)
            return nil
        } catch {
            #expect(pipeline == before, "\(error) changed the pipeline", sourceLocation: sourceLocation)
            return error
        }
    }

    static func ledger(
        _ pipeline: OSC.IntakePipeline, _ key: OSC.PeerKey = alpha, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> OSC.PeerLedger {
        try #require(pipeline.ledger(for: key), sourceLocation: sourceLocation)
    }
}

/// Bounded OSC intake: policy validation, the opt-in lifecycle and the gate order. The budget, framing and
/// principal suites live in the `+Budget`, `+Framing` and `+Principal` extensions.
@Suite("OSC bounded intake")
struct OSCTransportTests {
    typealias Fixture = OSCTransportFixture
    typealias OSC = OpenSoundControl
    typealias Refusal = OpenSoundControl.IntakeRefusal
    typealias Config = OpenSoundControl.EndpointRefusal

    // MARK: Policy validation

    @Test("A count knob accepts both ends of its range and refuses one beyond each", arguments: Fixture.countBounds)
    func countKnobsAcceptTheirRangeAndRefuseOneBeyond(_ bound: Fixture.CountBound) throws {
        for value in [bound.range.lowerBound, bound.range.upperBound] {
            try Fixture.build(bound.knob, value)
        }
        for value in [bound.range.lowerBound - 1, bound.range.upperBound + 1] {
            #expect(throws: Config.invalidCount(bound.knob, value)) { try Fixture.build(bound.knob, value) }
        }
    }

    @Test("Documented ceilings are the codec and scheduling ceilings")
    func ceilingsAreTheDocumentedOnes() {
        #expect(OSC.EndpointPolicy.peerLimit == 256)
        #expect(OSC.EndpointPolicy.packetBytesLimit == OSC.Limits.standard.maximumPacketBytes)
        #expect(OSC.EndpointPolicy.packetBytesLimit == 65_536)
        #expect(OSC.EndpointPolicy.bundleDepthLimit == OSC.SchedulingPolicy.bundleDepthLimit)
        #expect(OSC.EndpointPolicy.bundleDepthLimit == 64)
        #expect(OSC.EndpointPolicy.lengthHeaderBytes == 4)
        #expect(OSC.IntakeBudget.packetLimit == 65_536)
        #expect(OSC.IntakeBudget.byteLimit == 1_073_741_824)
        #expect(OSC.IntakeBudget.malformedLimit == 1_024)
    }

    @Test("A window, cooldown or idle span of zero is refused; one tick and the largest span are accepted")
    func tickKnobsNeedAtLeastOneTick() throws {
        #expect(throws: Config.invalidTicks(.window, 0)) { try Fixture.budget(window: 0) }
        #expect(throws: Config.invalidTicks(.cooldown, 0)) { try Fixture.budget(cooldown: 0) }
        #expect(throws: Config.invalidTicks(.idle, 0)) { try Fixture.policy(idle: 0) }
        for ticks in [1, .max] as [UInt64] {
            let allowance = try Fixture.budget(window: ticks, cooldown: ticks)
            #expect(allowance.windowTicks == ticks && allowance.cooldownTicks == ticks)
            #expect(try Fixture.policy(budget: Fixture.budget(window: ticks), idle: ticks).idleTicks == ticks)
        }
    }

    @Test("The byte allowance must fit one packet, and on a stream one whole chunk, and idle must cover the window")
    func crossFieldRulesAreInclusive() throws {
        let exact = try Fixture.policy(budget: Fixture.budget(bytes: 64), packetBytes: 64)
        #expect(exact.budget.maximumBytes == 64 && exact.maximumPacketBytes == 64)
        #expect(throws: Config.budgetCannotFitPacket(maximumBytes: 63, maximumPacketBytes: 64)) {
            try Fixture.policy(budget: Fixture.budget(bytes: 63), packetBytes: 64)
        }
        // A stream chunk is a packet plus its four byte length header: 68 bytes here. Datagrams need only 64.
        for framing in Fixture.framings {
            let whole = try Fixture.policy(.stream(framing), budget: Fixture.budget(bytes: 68), packetBytes: 64)
            #expect(whole.maximumChunkBytes == 68 && whole.budget.maximumBytes == 68)
            for bytes in 64...67 {
                #expect(throws: Config.budgetCannotFitChunk(maximumBytes: bytes, maximumChunkBytes: 68)) {
                    try Fixture.policy(.stream(framing), budget: Fixture.budget(bytes: bytes), packetBytes: 64)
                }
            }
            #expect(throws: Config.budgetCannotFitPacket(maximumBytes: 63, maximumPacketBytes: 64)) {
                try Fixture.policy(.stream(framing), budget: Fixture.budget(bytes: 63), packetBytes: 64)
            }
        }
        let covered = try Fixture.policy(budget: Fixture.budget(window: 10), idle: 10)
        #expect(covered.idleTicks == 10 && covered.budget.windowTicks == 10)
        #expect(throws: Config.idleBeforeWindowEnds(idleTicks: 9, windowTicks: 10)) {
            try Fixture.policy(budget: Fixture.budget(window: 10), idle: 9)
        }
    }

    @Test("Validation runs in one fixed order, so the refusal that is reported is deterministic")
    func validationOrderIsFixed() {
        #expect(throws: Config.invalidCount(.peers, 0)) {
            try Fixture.policy(peers: 0, idle: 0, packetBytes: 0, depth: 0)
        }
        #expect(throws: Config.invalidTicks(.idle, 0)) { try Fixture.policy(idle: 0, packetBytes: 0, depth: 0) }
        #expect(throws: Config.invalidCount(.packetBytes, 0)) { try Fixture.policy(packetBytes: 0, depth: 0) }
        #expect(throws: Config.invalidCount(.bundleDepth, 0)) {
            try Fixture.policy(budget: Fixture.budget(bytes: 8), depth: 0)
        }
        #expect(throws: Config.budgetCannotFitPacket(maximumBytes: 8, maximumPacketBytes: 1_024)) {
            try Fixture.policy(budget: Fixture.budget(bytes: 8), idle: 5)
        }
        // On a stream the packet rule is still first; the chunk rule comes before the idle rule, which a
        // datagram endpoint (that has no chunk rule) reports instead.
        #expect(throws: Config.budgetCannotFitPacket(maximumBytes: 8, maximumPacketBytes: 1_024)) {
            try Fixture.policy(.stream(.slip), budget: Fixture.budget(bytes: 8), idle: 5)
        }
        #expect(throws: Config.budgetCannotFitChunk(maximumBytes: 1_024, maximumChunkBytes: 1_028)) {
            try Fixture.policy(.stream(.slip), idle: 5)
        }
        #expect(throws: Config.idleBeforeWindowEnds(idleTicks: 5, windowTicks: 10)) { try Fixture.policy(idle: 5) }
        #expect(throws: Config.invalidTicks(.window, 0)) {
            try Fixture.budget(window: 0, packets: 0, bytes: 0, malformed: -1, cooldown: 0)
        }
        #expect(throws: Config.invalidCount(.packets, 0)) {
            try Fixture.budget(packets: 0, bytes: 0, malformed: -1, cooldown: 0)
        }
        #expect(throws: Config.invalidCount(.bytes, 0)) { try Fixture.budget(bytes: 0, malformed: -1, cooldown: 0) }
        #expect(throws: Config.invalidCount(.malformed, -1)) { try Fixture.budget(malformed: -1, cooldown: 0) }
        #expect(throws: Config.invalidTicks(.cooldown, 0)) { try Fixture.budget(cooldown: 0) }
    }

    @Test("A policy derives its codec limits, chunk size and buffered-byte bound from its knobs")
    func derivedBoundsFollowTheKnobs() throws {
        let policy = try Fixture.policy(peers: 7, packetBytes: 300, depth: 5)
        #expect(policy.limits == OSC.Limits(maximumPacketBytes: 300, maximumBundleDepth: 5))
        #expect(policy.maximumChunkBytes == 304)
        #expect(policy.bufferedByteBound == 7 * 304)
        #expect(policy.maximumPeers == 7 && policy.maximumPacketBytes == 300 && policy.maximumBundleDepth == 5)
        let defaults = try OSC.EndpointPolicy(
            transport: .stream(.slip), allowList: Fixture.allowList(), budget: Fixture.budget(bytes: 1 << 20),
            maximumPeers: 1, idleTicks: 10
        )
        #expect(defaults.maximumPacketBytes == 65_536 && defaults.maximumBundleDepth == 8)
        #expect(defaults.limits == OSC.Limits.standard)
        #expect(defaults.transport.framing == .slip && OSC.EndpointTransport.datagram.framing == nil)
        #expect(OSC.EndpointTransport.stream(.lengthPrefixed).framing == .lengthPrefixed)
    }

    // MARK: Opt-in lifecycle

    @Test("An endpoint is disabled by default and a disabled endpoint holds no state")
    func endpointStartsDisabledAndEmpty() throws {
        let pipeline = OSC.IntakePipeline()
        #expect(pipeline.endpoint == .disabled && !pipeline.endpoint.isEnabled && pipeline.endpoint.policy == nil)
        #expect(pipeline.peerCount == 0 && pipeline.peerKeys.isEmpty && pipeline.bufferedByteCount == 0)
        #expect(pipeline.latestTick == nil && pipeline.ledger(for: Fixture.alpha) == nil)
        #expect(pipeline.framerState(for: Fixture.alpha) == nil)
        var enabled = pipeline
        let policy = try Fixture.policy()
        #expect(Fixture.enable(&enabled, policy) == nil)
        #expect(enabled.endpoint == .enabled(policy) && enabled.endpoint.isEnabled && enabled.endpoint.policy == policy)
        #expect(enabled.peerCount == 0 && enabled.latestTick == nil)
    }

    @Test("A disabled endpoint refuses every call, charges nothing and creates no peer entry")
    func disabledEndpointRefusesAndChargesNothing() throws {
        let blank = OSC.IntakePipeline()
        var pipeline = blank
        #expect(Fixture.receive(&pipeline, try Fixture.datagram(), at: 3) == .failure(.endpointDisabled))
        #expect(Fixture.receive(&pipeline, Fixture.garbage, from: Fixture.bravo, at: 0) == .failure(.endpointDisabled))
        #expect(Fixture.chunk(&pipeline, [0xC0], at: 3) == .refused(.endpointDisabled))
        #expect(Fixture.expire(&pipeline, at: 3) == .failure(.endpointDisabled))
        #expect(pipeline == blank && pipeline.peerCount == 0 && pipeline.latestTick == nil)
    }

    @Test("A second enable is refused without changing the first policy; disable allows a new one")
    func enablingTwiceIsRefusedUntilDisabled() throws {
        var pipeline = OSC.IntakePipeline()
        let first = try Fixture.policy(peers: 2)
        let second = try Fixture.policy(peers: 3)
        #expect(Fixture.enable(&pipeline, first) == nil)
        Fixture.receive(&pipeline, try Fixture.datagram(), at: 1)
        let used = pipeline
        #expect(Fixture.enable(&pipeline, second) == .alreadyEnabled)
        #expect(Fixture.enable(&pipeline, first) == .alreadyEnabled)
        #expect(pipeline == used && pipeline.endpoint == .enabled(first) && pipeline.peerCount == 1)
        pipeline.disable()
        #expect(Fixture.enable(&pipeline, second) == nil)
        #expect(pipeline.endpoint == .enabled(second) && pipeline.peerCount == 0)
    }

    @Test("Disable discards every peer, framer and tick, and is idempotent")
    func disableDiscardsEverything() throws {
        var pipeline = try Fixture.pipeline(.stream(.lengthPrefixed), packetBytes: 64)
        Fixture.chunk(&pipeline, [0, 0, 0], from: Fixture.alpha, at: 4)
        Fixture.chunk(&pipeline, [0, 0, 0, 12], from: Fixture.bravo, at: 5)
        #expect(pipeline.peerCount == 2 && pipeline.latestTick == 5 && pipeline.bufferedByteCount == 3)
        pipeline.disable()
        #expect(pipeline == OSC.IntakePipeline() && pipeline.endpoint == .disabled)
        pipeline.disable()
        #expect(pipeline == OSC.IntakePipeline())
        #expect(Fixture.chunk(&pipeline, [0xC0], at: 0) == .refused(.endpointDisabled))
    }

    @Test("A datagram call on a stream endpoint and a chunk call on a datagram endpoint are wrong transport")
    func wrongTransportIsRefusedBeforeAnythingIsCharged() throws {
        var datagrams = try Fixture.pipeline(.datagram)
        #expect(Fixture.chunk(&datagrams, [0xC0], at: 1) == .refused(.wrongTransport(expected: .datagram)))
        #expect(datagrams.peerCount == 0 && datagrams.latestTick == nil)
        for framing in [OSC.StreamFraming.slip, .lengthPrefixed] {
            var streams = try Fixture.pipeline(.stream(framing), packetBytes: 64)
            let refusal = Refusal.wrongTransport(expected: .stream(framing))
            #expect(Fixture.receive(&streams, try Fixture.datagram(), at: 1) == .failure(refusal))
            #expect(streams.peerCount == 0 && streams.latestTick == nil)
            #expect(Fixture.expire(&streams, at: 2) == .success([]) && streams.latestTick == 2)
        }
        #expect(Fixture.expire(&datagrams, at: 2) == .success([]) && datagrams.latestTick == 2)
    }

    // MARK: Gate order and time

    @Test("Gate refusals follow one total order and every one leaves the pipeline equal")
    func gateOrderIsTotal() throws {
        var datagrams = try Fixture.pipeline()
        Fixture.receive(&datagrams, try Fixture.datagram(), at: 5)
        #expect(Fixture.chunk(&datagrams, [0xC0], at: 4) == .refused(.wrongTransport(expected: .datagram)))

        var streams = try Fixture.pipeline(.stream(.slip), peers: 1, packetBytes: 64)
        #expect(Fixture.chunk(&streams, [0xC0], at: 5) == .consumed([]))
        let oversize = [UInt8](repeating: 0x41, count: 69)
        #expect(Fixture.chunk(&streams, oversize, at: 4) == .refused(.tickRegressed(previous: 5, now: 4)))
        #expect(Fixture.chunk(&streams, oversize, from: Fixture.bravo, at: 5)
            == .refused(.chunkTooLarge(byteCount: 69, limit: 68)))
        #expect(Fixture.chunk(&streams, [0xC0], from: Fixture.bravo, at: 5) == .refused(.peerTableFull(limit: 1)))

        var tight = try Fixture.pipeline(packets: 1, bytes: 24, malformed: 0, peers: 1, packetBytes: 24)
        let wide = try Fixture.datagram(7, "/mixer/3/fader")
        var empty = tight
        let fits = try Fixture.accepted(7, "/mixer/3/fader")
        #expect(Fixture.receive(&empty, wide, from: Fixture.bravo, at: 0) == fits)
        #expect(try Fixture.go(&tight, at: 0) == Fixture.accepted())
        #expect(Fixture.receive(&tight, wide, from: Fixture.bravo, at: 1) == .failure(.peerTableFull(limit: 1)))
        #expect(Fixture.receive(&tight, wide, at: 1) == .failure(.packetBudgetExceeded(limit: 1, retryAfterTicks: 9)))
        var roomy = try Fixture.pipeline(packets: 2, bytes: 24, malformed: 0, peers: 1, packetBytes: 24)
        try Fixture.go(&roomy, at: 0)
        #expect(Fixture.receive(&roomy, wide, at: 1) == .failure(.byteBudgetExceeded(limit: 24, retryAfterTicks: 9)))

        var strict = try Fixture.pipeline(packets: 1, malformed: 0)
        #expect(Fixture.receive(&strict, Fixture.garbage, at: 0) == .failure(.malformed(.unrecognizedPacket)))
        #expect(Fixture.receive(&strict, wide, at: 1) == .failure(.peerQuarantined(retryAfterTicks: 19)))
    }

    @Test("Time never runs backwards: a regressed tick is a typed refusal, an equal tick is allowed")
    func tickRegressionIsTypedAndLeavesStateEqual() throws {
        var pipeline = try Fixture.pipeline()
        #expect(try Fixture.go(&pipeline, 1, at: 5) == Fixture.accepted(1))
        #expect(pipeline.latestTick == 5)
        let regressed = Refusal.tickRegressed(previous: 5, now: 4)
        #expect(try Fixture.go(&pipeline, at: 4) == .failure(regressed))
        #expect(try Fixture.go(&pipeline, from: Fixture.bravo, at: 4) == .failure(regressed))
        let zero = Refusal.tickRegressed(previous: 5, now: 0)
        #expect(Fixture.receive(&pipeline, Fixture.garbage, from: Fixture.charlie, at: 0) == .failure(zero))
        #expect(Fixture.expire(&pipeline, at: 4) == .failure(regressed))
        #expect(pipeline.latestTick == 5 && pipeline.peerCount == 1)
        #expect(try Fixture.go(&pipeline, 2, from: Fixture.bravo, at: 5) == Fixture.accepted(2))
        #expect(try Fixture.go(&pipeline, 3, at: 6) == Fixture.accepted(3))
        #expect(pipeline.latestTick == 6 && pipeline.peerKeys == [Fixture.alpha, Fixture.bravo])
        #expect(Fixture.expire(&pipeline, at: 6) == .success([]) && pipeline.latestTick == 6)
    }

    @Test("A refused call does not advance time but a successful expire does")
    func onlyAcceptedWorkAdvancesTime() throws {
        var pipeline = try Fixture.pipeline(packets: 1)
        try Fixture.go(&pipeline, at: 2)
        #expect(try Fixture.go(&pipeline, at: 8) == .failure(.packetBudgetExceeded(limit: 1, retryAfterTicks: 4)))
        #expect(pipeline.latestTick == 2)
        #expect(Fixture.expire(&pipeline, at: 8) == .success([]))
        #expect(pipeline.latestTick == 8)
        #expect(try Fixture.go(&pipeline, at: 7) == .failure(.tickRegressed(previous: 8, now: 7)))
    }
}
