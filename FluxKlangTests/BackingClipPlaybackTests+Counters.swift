import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension BackingClipPlaybackTests {
    static func ceilingSpec(_ ceiling: Int64, loop: BackingClipLoop? = nil,
                            underrun: BackingUnderrunPolicy = .silenceAndReport) throws -> BackingClipSpec {
        try spec(loop: loop, underrun: underrun).withCounterCeiling(ceiling)
    }

    @Test
    func backingCounterGuardAdmitsExactlyUpToTheCeiling() {
        #expect(BackingCounterGuard.capacityAdmits(current: 9, adding: 1, ceiling: 10))
        #expect(!BackingCounterGuard.capacityAdmits(current: 9, adding: 2, ceiling: 10))
        #expect(BackingCounterGuard.capacityAdmits(current: 0, adding: 10, ceiling: 10))
        #expect(!BackingCounterGuard.capacityAdmits(current: 0, adding: 11, ceiling: 10))
        #expect(BackingCounterGuard.capacityAdmits(current: 10, adding: 0, ceiling: 10))
        #expect(!BackingCounterGuard.capacityAdmits(current: 11, adding: 0, ceiling: 10))
        #expect(!BackingCounterGuard.capacityAdmits(current: -1, adding: 1, ceiling: 10))
        #expect(!BackingCounterGuard.capacityAdmits(current: 1, adding: -1, ceiling: 10))
        #expect(BackingCounterGuard.capacityAdmits(current: Int64.max, adding: 0, ceiling: Int64.max))
        #expect(!BackingCounterGuard.capacityAdmits(current: Int64.max, adding: 1, ceiling: Int64.max))
        #expect(BackingCounterGuard.capacityAdmits(current: 0, adding: Int64.max, ceiling: Int64.max))
        #expect(!BackingCounterGuard.capacityAdmits(current: Int64.max - 1, adding: 2, ceiling: Int64.max))
    }

    @Test
    func backingSpecCounterCeilingDefaultsToInt64MaxAndRefusesANegativeValue() throws {
        let base = try Self.spec(loop: BackingClipLoop(startFrame: 1, endFrame: 9), underrun: .stopVoice)
        #expect(base.counterCeiling == Int64.max)
        let zero = try base.withCounterCeiling(0)
        #expect(zero.counterCeiling == 0 && zero.loop == base.loop && zero.underrun == .stopVoice)
        #expect(zero.totalFrames == base.totalFrames && zero.action == base.action)
        #expect(throws: BackingClipRefusal.counterCeilingNegative(-1)) { try base.withCounterCeiling(-1) }
        #expect(try base.withCounterCeiling(Int64.max) == base)
    }

    @Test
    func backingRenderRefusesWhenTheUnderrunCounterWouldPassTheCeiling() throws {
        var accepted = try Self.playing(Self.ceilingSpec(10))
        #expect(try accepted.render(frames: 10, at: Self.sample(0)).renderedFrames == 10)
        #expect(accepted.underrunFrames == 10)
        var refused = try Self.playing(Self.ceilingSpec(10))
        let before = refused.snapshot
        #expect(throws: BackingClipRefusal.counterWouldOverflow(.underrunFrames)) {
            try refused.render(frames: 11, at: Self.sample(0))
        }
        #expect(refused.snapshot == before && refused.playhead.underrunFrames == 0)
        let full = accepted.snapshot
        #expect(throws: BackingClipRefusal.counterWouldOverflow(.underrunFrames)) {
            try accepted.render(frames: 1, at: Self.sample(10))
        }
        #expect(accepted.snapshot == full)
    }

    @Test
    func backingStopVoiceRenderIsCheckedAgainstTheUnderrunCeilingBeforeProbing() throws {
        var refused = try Self.playing(Self.ceilingSpec(10, underrun: .stopVoice))
        let before = refused.snapshot
        #expect(throws: BackingClipRefusal.counterWouldOverflow(.underrunFrames)) {
            try refused.render(frames: 11, at: Self.sample(0))
        }
        #expect(refused.snapshot == before && refused.state == .playing)
        var accepted = try Self.playing(Self.ceilingSpec(10, underrun: .stopVoice))
        let render = try accepted.render(frames: 10, at: Self.sample(0))
        #expect(render.stopped == .underrun && accepted.underrunFrames == 10)
    }

    @Test
    func backingInsertOfAStaleBlockIsRefusedWhenTheDiscardCounterWouldPassTheCeiling() throws {
        var voice = try Self.playing(Self.ceilingSpec(3), read: 2)
        let stale = try Self.block(0, read: 1)
        for _ in 0..<3 { #expect(try voice.insert(stale) == .discardedStale) }
        #expect(voice.snapshot.discardedStaleBlocks == 3)
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.counterWouldOverflow(.discardedStaleBlocks)) { try voice.insert(stale) }
        #expect(voice.snapshot == before)
        #expect(try voice.insert(Self.block(0, read: 2)) == .resident)
    }

    @Test
    func backingSeekIsRefusedWhenTheDroppedBlocksWouldPassTheDiscardCeiling() throws {
        for (ceiling, accepted) in [(Int64(4), true), (3, false)] {
            var voice = try Self.playing(Self.ceilingSpec(ceiling))
            try voice.insert(Self.block(0))
            try voice.insert(Self.block(64))
            try voice.seek(to: 10)
            try voice.insert(Self.block(300, read: 2))
            try voice.insert(Self.block(364, read: 2))
            let before = voice.snapshot
            if accepted {
                try voice.seek(to: 500)
                #expect(voice.snapshot.discardedStaleBlocks == 4 && voice.position == 500)
            } else {
                #expect(throws: BackingClipRefusal.counterWouldOverflow(.discardedStaleBlocks)) {
                    try voice.seek(to: 500)
                }
                #expect(voice.snapshot == before)
            }
        }
    }

    @Test
    func backingWrapIsRefusedBeforeServingWhenTheDroppedBlocksWouldPassTheDiscardCeiling() throws {
        for (ceiling, accepted) in [(Int64(5), true), (4, false)] {
            let loop = BackingClipLoop(startFrame: 0, endFrame: 200)
            var voice = try Self.playing(Self.ceilingSpec(ceiling, loop: loop))
            try voice.seek(to: 199)
            let stale = try Self.block(0, read: 1)
            for _ in 0..<3 { try voice.insert(stale) }
            try voice.insert(Self.block(199, 1, read: 2))
            try voice.insert(Self.block(200, read: 2))
            let before = voice.snapshot
            if accepted {
                let render = try voice.render(frames: 1, at: Self.sample(0))
                #expect(render.outcome == .loopWrapped(unrenderedFrames: 0))
                #expect(voice.snapshot.discardedStaleBlocks == 4 && voice.position == 0)
            } else {
                #expect(throws: BackingClipRefusal.counterWouldOverflow(.discardedStaleBlocks)) {
                    try voice.render(frames: 1, at: Self.sample(0))
                }
                #expect(voice.snapshot == before && voice.hasPendingLocate)
            }
        }
    }

    @Test
    func backingGenerationExhaustionIsReportedBeforeTheCounterCeilings() throws {
        let loop = BackingClipLoop(startFrame: 0, endFrame: 200)
        var voice = try Self.playing(Self.ceilingSpec(0, loop: loop), read: UInt64.max)
        try voice.insert(Self.block(0, read: UInt64.max))
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.prefetch(.generationOverflow)) {
            try voice.render(frames: 200, at: Self.sample(0))
        }
        #expect(voice.snapshot == before)
    }

    @Test
    func backingSeekReportsGenerationExhaustionBeforeTheDiscardCeiling() throws {
        var voice = try Self.playing(Self.ceilingSpec(0), read: UInt64.max)
        try voice.insert(Self.block(0, read: UInt64.max))
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.prefetch(.generationOverflow)) { try voice.seek(to: 5) }
        #expect(voice.snapshot == before)
    }

    @Test
    func backingWrapReportsTheUnderrunCeilingBeforeTheDiscardCeilingWhenBothAreAtTheirLimit() throws {
        let loop = BackingClipLoop(startFrame: 0, endFrame: 200)
        var voice = try Self.playing(Self.ceilingSpec(3, loop: loop))
        _ = try voice.render(frames: 3, at: Self.sample(0))
        try voice.seek(to: 199)
        let stale = try Self.block(0, read: 1)
        for _ in 0..<3 { try voice.insert(stale) }
        try voice.insert(Self.block(199, 1, read: 2))
        #expect(voice.underrunFrames == 3 && voice.snapshot.discardedStaleBlocks == 3)
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.counterWouldOverflow(.underrunFrames)) {
            try voice.render(frames: 1, at: Self.sample(10))
        }
        #expect(voice.snapshot == before)
    }

    @Test
    func backingInsertGuardsTheDiscardCounterBeforePF1ChecksTheBlockLength() throws {
        var voice = try Self.playing(Self.ceilingSpec(1))
        try voice.seek(to: 5)
        let tooLongAndStale = try Self.block(0, 65, read: 1)
        let bare = voice.playhead.plan.blockFrames
        #expect(throws: BackingClipRefusal.prefetch(.blockTooLong(frames: 65, blockFrames: bare))) {
            try voice.insert(tooLongAndStale)
        }
        #expect(try voice.insert(Self.block(0, read: 1)) == .discardedStale)
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.counterWouldOverflow(.discardedStaleBlocks)) {
            try voice.insert(tooLongAndStale)
        }
        #expect(voice.snapshot == before)
    }
}
