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
}
