import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The backing-clip voice state machine (#111 PB1). This root file holds the shared builders and the arm tests.
@Suite("Backing clip playback voice")
struct BackingClipPlaybackTests {
    static let action = ActionID(validated: "act.backing")
    static let sourceKey = GenerationKey(kind: .source, subject: GenerationSubject(validated: "src.clip"))
    static let mapKey = GenerationKey(.musicalMap, ClockID(validated: "mus.main"))

    /// A render summary that compares every field of a `RuntimeDiscontinuity`.
    struct Event: Equatable {
        let kind: String
        let frame: Int64
        let frames: UInt32?
        let stream: UInt32?
    }

    /// 4 × 64-frame blocks: the pool holds 256 frames.
    static func plan() throws -> PrefetchPlan {
        try PrefetchPlan.make(blockFrames: 64, blockCount: 4, headFrames: 128)
    }

    static func spec(total: Int64 = 1000, loop: BackingClipLoop? = nil,
                     underrun: BackingUnderrunPolicy = .silenceAndReport) throws -> BackingClipSpec {
        try BackingClipSpec.make(action: action, totalFrames: total, loop: loop, timePolicy: .fixedRate,
                                 underrun: underrun)
    }

    static func voice(_ spec: BackingClipSpec, read: UInt64 = 1) throws -> BackingClipVoice {
        try BackingClipVoice.make(spec: spec, plan: plan(), stream: 7, sourceGeneration: 1, readGeneration: read)
    }

    static func ledger() throws -> GenerationLedger {
        try GenerationLedger(primaryClock: ClockID(validated: "clk.main"), musicalClock: ClockID(validated: "mus.main"),
                             nominalRate: 48_000, declaring: [sourceKey])
    }

    /// The action prepared against the source counter (and `extra`) at their current generations.
    static func readiness(_ ledger: GenerationLedger, extra: [GenerationKey] = []) throws -> ActionReadiness {
        var readiness = ActionReadiness()
        try readiness.transition(action, to: .preparing)
        var requirements: [GenerationRequirement] = []
        for key in [sourceKey] + extra {
            let generation = try #require(ledger.generation(key))
            requirements.append(GenerationRequirement(key: key, generation: generation))
        }
        try readiness.markReady(action, preparedAgainst: requirements, ledger: ledger)
        return readiness
    }

    static func armed(_ spec: BackingClipSpec, read: UInt64 = 1) throws -> BackingClipVoice {
        var voice = try voice(spec, read: read)
        let ledger = try ledger()
        try voice.arm(readiness: readiness(ledger), ledger: ledger)
        return voice
    }

    static func playing(_ spec: BackingClipSpec, read: UInt64 = 1) throws -> BackingClipVoice {
        var voice = try armed(spec, read: read)
        try voice.play()
        return voice
    }

    static func block(_ start: Int64, _ frames: Int = 64, read: UInt64 = 1) throws -> PrefetchBlock {
        try PrefetchBlock.make(startFrame: start, frames: frames, sourceGeneration: 1, readGeneration: read)
    }

    static func sample(_ frame: Int64) -> RuntimeSampleStamp {
        RuntimeSampleStamp(clock: 3, generation: 1, frame: frame)
    }

    static func events(_ render: BackingRender) -> [Event] {
        render.discontinuities.map { event in
            let kind: String
            switch event.kind {
            case .locate: kind = "locate"
            case .loopWrap: kind = "loopWrap"
            case .underrun: kind = "underrun"
            default: kind = "other"
            }
            let stampOK = event.sample.clock == 3 && event.sample.generation == 1
            return Event(kind: stampOK ? kind : "badStamp", frame: event.sample.frame, frames: event.frames,
                         stream: event.stream)
        }
    }

    static func event(_ kind: String, _ frame: Int64, _ frames: UInt32? = nil) -> Event {
        Event(kind: kind, frame: frame, frames: frames, stream: 7)
    }

    // MARK: Arming

    @Test
    func backingVoiceStartsDisarmedEvenWhenTheActionIsAlreadyReady() throws {
        let ledger = try Self.ledger()
        let ready = try Self.readiness(ledger)
        #expect(ready.isCurrent(Self.action, ledger: ledger))
        var voice = try Self.voice(Self.spec())
        #expect(voice.state == .disarmed && voice.position == 0 && !voice.hasPendingLocate)
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.notArmed) { try voice.play() }
        #expect(throws: BackingClipRefusal.notPlaying(.disarmed)) {
            try voice.render(frames: 1, at: Self.sample(0))
        }
        #expect(voice.snapshot == before)
    }

    @Test
    func backingArmAcceptsOnlyReadyReadiness() throws {
        let ledger = try Self.ledger()
        var voice = try Self.voice(Self.spec())
        let before = voice.snapshot
        var machine = ActionReadiness()
        #expect(throws: BackingClipRefusal.notReady(.unprepared)) { try voice.arm(readiness: machine, ledger: ledger) }
        try machine.transition(Self.action, to: .preparing)
        #expect(throws: BackingClipRefusal.notReady(.preparing)) { try voice.arm(readiness: machine, ledger: ledger) }
        try machine.transition(Self.action, to: .failed)
        #expect(throws: BackingClipRefusal.notReady(.failed)) { try voice.arm(readiness: machine, ledger: ledger) }
        var invalidated = try Self.readiness(ledger)
        invalidated.generationChanged(Self.sourceKey)
        #expect(throws: BackingClipRefusal.notReady(.invalidated)) {
            try voice.arm(readiness: invalidated, ledger: ledger)
        }
        #expect(voice.snapshot == before && voice.state == .disarmed)
        try voice.arm(readiness: Self.readiness(ledger), ledger: ledger)
        #expect(voice.state == .armed)
    }

    @Test
    func backingArmRefusesAStaleDependencyGeneration() throws {
        var ledger = try Self.ledger()
        let ready = try Self.readiness(ledger)
        try ledger.bump(Self.sourceKey, reason: .sourceLost)
        var voice = try Self.voice(Self.spec())
        let before = voice.snapshot
        #expect(ready.state(Self.action) == .ready)
        #expect(throws: BackingClipRefusal.staleDependencies) { try voice.arm(readiness: ready, ledger: ledger) }
        #expect(voice.snapshot == before && voice.state == .disarmed)
    }

    @Test
    func backingArmRefusalChecksTheVoiceStateBeforeReadiness() throws {
        let ledger = try Self.ledger()
        let unprepared = ActionReadiness()
        var armed = try Self.armed(Self.spec())
        #expect(throws: BackingClipRefusal.alreadyArmed) { try armed.arm(readiness: unprepared, ledger: ledger) }
        var playing = try Self.playing(Self.spec())
        #expect(throws: BackingClipRefusal.alreadyPlaying) { try playing.arm(readiness: unprepared, ledger: ledger) }
        var stopped = try Self.voice(Self.spec())
        try stopped.stop()
        #expect(throws: BackingClipRefusal.voiceStopped(.requested)) {
            try stopped.arm(readiness: unprepared, ledger: ledger)
        }
        var disarmed = try Self.voice(Self.spec())
        #expect(throws: BackingClipRefusal.notReady(.unprepared)) {
            try disarmed.arm(readiness: unprepared, ledger: ledger)
        }
        #expect(armed.state == .armed && playing.state == .playing && stopped.state == .stopped(.requested))
    }

    @Test
    func backingVoiceMakeRefusesAZeroSourceGeneration() throws {
        let spec = try Self.spec()
        #expect(throws: BackingClipRefusal.prefetch(.sourceGenerationNotPositive)) {
            try BackingClipVoice.make(spec: spec, plan: Self.plan(), stream: 7, sourceGeneration: 0,
                                      readGeneration: 1)
        }
        #expect(throws: Never.self) {
            try BackingClipVoice.make(spec: spec, plan: Self.plan(), stream: 7, sourceGeneration: 1,
                                      readGeneration: 0)
        }
    }
}
