import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension BackingClipPlaybackTests {
    @Test
    func backingPlayMovesArmedToPlayingAndRefusesTheOtherStates() throws {
        var armed = try Self.armed(Self.spec())
        try armed.play()
        #expect(armed.state == .playing)
        let playing = armed.snapshot
        #expect(throws: BackingClipRefusal.alreadyPlaying) { try armed.play() }
        #expect(armed.snapshot == playing)
        var stopped = try Self.armed(Self.spec())
        try stopped.stop()
        let before = stopped.snapshot
        #expect(throws: BackingClipRefusal.voiceStopped(.requested)) { try stopped.play() }
        #expect(stopped.snapshot == before)
    }

    @Test
    func backingDisarmReturnsToDisarmedAndKeepsThePosition() throws {
        var voice = try Self.playing(Self.spec())
        try voice.insert(Self.block(0))
        _ = try voice.render(frames: 10, at: Self.sample(0))
        try voice.disarm()
        #expect(voice.state == .disarmed && voice.position == 10)
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.notArmed) { try voice.disarm() }
        #expect(throws: BackingClipRefusal.notArmed) { try voice.play() }
        #expect(voice.snapshot == before)
        var armed = try Self.armed(Self.spec())
        try armed.disarm()
        #expect(armed.state == .disarmed)
    }

    @Test
    func backingStopWorksFromEveryLiveStateAndIsTerminal() throws {
        var disarmed = try Self.voice(Self.spec())
        var armed = try Self.armed(Self.spec())
        var playing = try Self.playing(Self.spec())
        for index in 0..<3 {
            switch index {
            case 0: try disarmed.stop()
            case 1: try armed.stop()
            default: try playing.stop()
            }
        }
        #expect(disarmed.state == .stopped(.requested) && armed.state == .stopped(.requested))
        #expect(playing.state == .stopped(.requested))
        let before = playing.snapshot
        #expect(throws: BackingClipRefusal.voiceStopped(.requested)) { try playing.stop() }
        #expect(throws: BackingClipRefusal.voiceStopped(.requested)) { try playing.disarm() }
        #expect(throws: BackingClipRefusal.voiceStopped(.requested)) { try playing.seek(to: 1) }
        #expect(throws: BackingClipRefusal.voiceStopped(.requested)) { try playing.insert(Self.block(0)) }
        #expect(throws: BackingClipRefusal.voiceStopped(.requested)) {
            try playing.render(frames: 1, at: Self.sample(0))
        }
        #expect(playing.snapshot == before)
    }

    @Test
    func backingSeekBoundsAreZeroThroughTotalMinusOne() throws {
        let spec = try Self.spec(total: 1000)
        var voice = try Self.playing(spec)
        try voice.insert(Self.block(0))
        let before = voice.snapshot
        for bad in [Int64(-1), 1000, Int64.max, Int64.min] {
            #expect(throws: BackingClipRefusal.seekOutOfRange(frame: bad, totalFrames: 1000)) {
                try voice.seek(to: bad)
            }
            #expect(voice.snapshot == before)
        }
        try voice.seek(to: 999)
        #expect(voice.position == 999)
        try voice.seek(to: 0)
        #expect(voice.position == 0 && voice.state == .playing)
    }

    @Test
    func backingSeekStartsANewReadAndDropsResidentBlocks() throws {
        var voice = try Self.playing(Self.spec())
        try voice.insert(Self.block(0))
        try voice.insert(Self.block(64))
        try voice.seek(to: 500)
        #expect(voice.readGeneration == 2 && voice.residentBlocks.isEmpty)
        #expect(voice.snapshot.discardedStaleBlocks == 2 && voice.position == 500)
        #expect(voice.hasPendingLocate && voice.state == .playing)
        #expect(try voice.insert(Self.block(500, read: 1)) == .discardedStale)
        #expect(try voice.insert(Self.block(500, read: 2)) == .resident)
        #expect(voice.snapshot.discardedStaleBlocks == 3)
    }

    @Test
    func backingSeekIsAllowedWhileDisarmedAndArmed() throws {
        var disarmed = try Self.voice(Self.spec())
        try disarmed.seek(to: 40)
        #expect(disarmed.state == .disarmed && disarmed.position == 40 && disarmed.hasPendingLocate)
        var armed = try Self.armed(Self.spec())
        try armed.seek(to: 41)
        #expect(armed.state == .armed && armed.position == 41)
    }

    @Test
    func backingSeekRefusesWhenTheReadGenerationCannotAdvance() throws {
        var voice = try Self.playing(Self.spec(), read: UInt64.max)
        try voice.insert(Self.block(0, read: UInt64.max))
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.prefetch(.generationOverflow)) { try voice.seek(to: 5) }
        #expect(voice.snapshot == before)
    }

    @Test
    func backingInsertDelegatesToThePlayheadAndLeavesRefusalsUnchanged() throws {
        var voice = try Self.playing(Self.spec())
        #expect(try voice.insert(Self.block(0)) == .resident)
        #expect(try voice.insert(Self.block(64, read: 0)) == .discardedStale)
        let resident = try Self.block(0)
        #expect(voice.snapshot.discardedStaleBlocks == 1 && voice.residentBlocks == [resident])
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.prefetch(.generationAhead(source: 1, read: 2))) {
            try voice.insert(Self.block(64, read: 2))
        }
        #expect(throws: BackingClipRefusal.prefetch(.overlappingBlock(startFrame: 32, frames: 64))) {
            try voice.insert(Self.block(32))
        }
        #expect(throws: BackingClipRefusal.prefetch(.blockTooLong(frames: 65, blockFrames: 64))) {
            try voice.insert(Self.block(200, 65))
        }
        #expect(voice.snapshot == before)
    }

    @Test
    func backingInsertRefusesAFullPoolWithoutChange() throws {
        var voice = try Self.playing(Self.spec())
        for start in [Int64(0), 64, 128, 192] { try voice.insert(Self.block(start)) }
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.prefetch(.poolFull(blockCount: 4))) { try voice.insert(Self.block(256)) }
        #expect(voice.snapshot == before)
    }
}
