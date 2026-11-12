import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension BackingClipPlaybackTests {
    static func changed(_ voice: inout BackingClipVoice, _ readiness: ActionReadiness,
                        _ ledger: GenerationLedger) -> Bool {
        voice.readinessChanged(readiness: readiness, ledger: ledger)
    }
    @Test
    func backingReadinessLossStopsAPlayingVoiceAndNeverReArms() throws {
        var ledger = try Self.ledger()
        var readiness = try Self.readiness(ledger)
        var voice = try Self.playing(Self.spec())
        try voice.insert(Self.block(0))
        _ = try voice.render(frames: 10, at: Self.sample(0))
        #expect(!Self.changed(&voice, readiness, ledger) && voice.state == .playing)
        try ledger.bump(Self.sourceKey, reason: .sourceLost)
        #expect(Self.changed(&voice, readiness, ledger))
        #expect(voice.state == .stopped(.readinessLost) && voice.position == 10)
        readiness.generationChanged(Self.sourceKey)
        try readiness.transition(Self.action, to: .preparing)
        let requirement = try GenerationRequirement(key: Self.sourceKey,
                                                    generation: #require(ledger.generation(Self.sourceKey)))
        try readiness.markReady(Self.action, preparedAgainst: [requirement], ledger: ledger)
        #expect(readiness.isCurrent(Self.action, ledger: ledger))
        let before = voice.snapshot
        #expect(!Self.changed(&voice, readiness, ledger))
        #expect(throws: BackingClipRefusal.voiceStopped(.readinessLost)) {
            try voice.arm(readiness: readiness, ledger: ledger)
        }
        #expect(voice.snapshot == before && voice.state == .stopped(.readinessLost))
    }

    @Test
    func backingReadinessLossStopsAnArmedVoiceButNotADisarmedOrStoppedOne() throws {
        let ledger = try Self.ledger()
        var invalidated = try Self.readiness(ledger)
        invalidated.generationChanged(Self.sourceKey)
        var armed = try Self.armed(Self.spec())
        var disarmed = try Self.voice(Self.spec())
        var stopped = try Self.voice(Self.spec())
        try stopped.stop()
        #expect(Self.changed(&armed, invalidated, ledger))
        #expect(armed.state == .stopped(.readinessLost))
        let before = disarmed.snapshot
        #expect(!Self.changed(&disarmed, invalidated, ledger) && disarmed.snapshot == before)
        #expect(!Self.changed(&stopped, invalidated, ledger))
        #expect(stopped.state == .stopped(.requested))
    }

    @Test
    func backingReadinessChangedStopsAVoiceWhoseActionWasNeverPrepared() throws {
        let ledger = try Self.ledger()
        var voice = try Self.playing(Self.spec())
        #expect(Self.changed(&voice, ActionReadiness(), ledger))
        #expect(voice.state == .stopped(.readinessLost))
    }

    @Test
    func backingTempoChangeThatOnlyTouchesTheMusicalMapKeepsThePlayingVoiceRendering() throws {
        var ledger = try Self.ledger()
        let readiness = try Self.readiness(ledger)
        var voice = try Self.playing(Self.spec())
        try voice.insert(Self.block(0))
        try voice.insert(Self.block(64))
        let first = try voice.render(frames: 64, at: Self.sample(0))
        try ledger.bump(Self.mapKey, reason: .tempoEdit)
        try ledger.bump(Self.mapKey, reason: .externalTempo)
        #expect(!Self.changed(&voice, readiness, ledger))
        let second = try voice.render(frames: 64, at: Self.sample(64))
        #expect(first.segments == [.served(sourceFrame: 0, frames: 64)])
        #expect(second.segments == [.served(sourceFrame: 64, frames: 64)] && second.discontinuities.isEmpty)
        #expect(voice.state == .playing && voice.readGeneration == 1 && voice.position == 128)
    }

    @Test
    func backingActionPreparedAgainstTheMusicalMapStopsWhenTheMapChanges() throws {
        var ledger = try Self.ledger()
        let readiness = try Self.readiness(ledger, extra: [Self.mapKey])
        var voice = try Self.playing(Self.spec())
        try ledger.bump(Self.mapKey, reason: .tempoEdit)
        #expect(Self.changed(&voice, readiness, ledger))
        #expect(voice.state == .stopped(.readinessLost))
    }

    @Test
    func backingStaleReadBlocksAreDiscardedNotServed() throws {
        var voice = try Self.playing(Self.spec())
        try voice.insert(Self.block(0))
        let staleRead = try Self.block(64, read: 0)
        #expect(try voice.insert(staleRead) == .discardedStale)
        let render = try voice.render(frames: 128, at: Self.sample(0))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64), .silence(sourceFrame: 64, frames: 64)])
        #expect(voice.snapshot.discardedStaleBlocks == 1)
    }

    // MARK: Start mapping against the voice (BJ1)

    /// Renders `offset` output frames from frame 0 in legal chunks (≤ pool, ≤ loop); stops early at the clip end.
    static func renderFromZero(_ voice: inout BackingClipVoice, frames offset: Int64) throws {
        var remaining = offset
        var clock: Int64 = 0
        let cap = min(Int64(voice.playhead.plan.poolFrames), voice.spec.loopFrames ?? Int64.max)
        while remaining > 0, voice.state == .playing {
            let render = try voice.render(frames: Int(min(remaining, cap)), at: sample(clock))
            remaining -= Int64(render.renderedFrames)
            clock += Int64(render.renderedFrames)
        }
    }

    @Test
    func backingStartMatchesRenderingTheJoinOffsetFromFrameZero() throws {
        var random = BackingJoinRandom(state: 0xB1)
        let specs = try [
            Self.spec(total: 1000), Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 0, endFrame: 1000)),
            Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 0, endFrame: 64)),
            Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 100, endFrame: 300)),
            Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 990, endFrame: 1000)),
            Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 5, endFrame: 6))
        ]
        for spec in specs {
            var offsets: [Int64] = [1, 63, 64, 99, 100, 299, 300, 301, 999, 1000, 1001, 2_000]
            for _ in 0..<12 { offsets.append(Int64(random.next() % 3_000) + 1) }
            for offset in offsets {
                var rendered = try Self.playing(spec)
                try Self.renderFromZero(&rendered, frames: offset)
                let mapped = try BackingClipStart.make(outcome: Self.joined(offset), spec: spec)
                guard case .start(let frame) = mapped else {
                    #expect(mapped == .ended(startOffsetFrames: offset) && spec.loop == nil, "offset \(offset)")
                    #expect(rendered.state == .stopped(.reachedEnd) && rendered.position == spec.totalFrames)
                    continue
                }
                #expect(rendered.state == .playing && rendered.position == frame, "offset \(offset) \(spec)")
                var joined = try Self.playing(spec)
                #expect(try joined.locate(to: mapped))
                let next = Int(min(spec.loopFrames ?? 50, 50))
                let fromZero = try rendered.render(frames: next, at: Self.sample(0))
                let fromJoin = try joined.render(frames: next, at: Self.sample(0))
                #expect(fromZero.segments == fromJoin.segments && fromZero.outcome == fromJoin.outcome)
            }
        }
    }

    @Test
    func backingLocateToAStartKeepsTheHeadAtFrameZeroAndSeeksAwayFromIt() throws {
        var voice = try Self.playing(Self.spec())
        try voice.insert(Self.block(0))
        #expect(try voice.locate(to: .start(frame: 0)))
        #expect(voice.readGeneration == 1 && voice.residentBlocks.count == 1 && !voice.hasPendingLocate)
        #expect(try voice.locate(to: .start(frame: 500)))
        #expect(voice.position == 500 && voice.readGeneration == 2 && voice.residentBlocks.isEmpty)
        #expect(voice.hasPendingLocate && voice.state == .playing)
        let render = try voice.render(frames: 10, at: Self.sample(0))
        #expect(render.segments == [.silence(sourceFrame: 500, frames: 10)])
        #expect(Self.events(render) == [Self.event("locate", 0), Self.event("underrun", 0, 10)])
        var strict = try Self.playing(Self.spec(underrun: .stopVoice))
        #expect(try strict.locate(to: .start(frame: 500)))
        let stopped = try strict.render(frames: 10, at: Self.sample(0))
        #expect(stopped.renderedFrames == 0 && strict.state == .stopped(.underrun))
    }

    @Test
    func backingLocateLeavesTheVoiceAloneWhenTheClipDoesNotStart() throws {
        var voice = try Self.armed(Self.spec())
        let before = voice
        #expect(try !voice.locate(to: .ended(startOffsetFrames: 1000)))
        #expect(try !voice.locate(to: .notStarted(.dropped)))
        #expect(voice == before && voice.state == .armed)
        #expect(throws: BackingClipRefusal.seekOutOfRange(frame: 1000, totalFrames: 1000)) {
            try voice.locate(to: .start(frame: 1000))
        }
        #expect(voice == before)
        try voice.stop()
        for start in [BackingClipStart.start(frame: 0), .ended(startOffsetFrames: 1), .notStarted(.cancelled)] {
            #expect(throws: BackingClipRefusal.voiceStopped(.requested)) { try voice.locate(to: start) }
        }
    }
}

/// SplitMix64: deterministic offsets for the join render-equivalence property.
private struct BackingJoinRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
