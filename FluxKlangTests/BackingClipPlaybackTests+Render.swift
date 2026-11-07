import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension BackingClipPlaybackTests {
    @Test
    func backingRenderServesResidentFramesExactly() throws {
        var voice = try Self.playing(Self.spec())
        try voice.insert(Self.block(0))
        try voice.insert(Self.block(64))
        let render = try voice.render(frames: 100, at: Self.sample(1000))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64), .served(sourceFrame: 64, frames: 36)])
        #expect(render.discontinuities.isEmpty && render.renderedFrames == 100 && render.stopped == nil)
        #expect(voice.position == 100 && voice.state == .playing && voice.underrunFrames == 0)
        let second = try Self.block(64)
        #expect(voice.residentBlocks == [second])
    }

    @Test
    func backingRenderReportsAGapAsSilenceAndAnUnderrunAndKeepsPlaying() throws {
        var voice = try Self.playing(Self.spec())
        try voice.insert(Self.block(0))
        try voice.insert(Self.block(128))
        let render = try voice.render(frames: 192, at: Self.sample(500))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64), .silence(sourceFrame: 64, frames: 64),
                                    .served(sourceFrame: 128, frames: 64)])
        #expect(Self.events(render) == [Self.event("underrun", 564, 64)])
        #expect(render.renderedFrames == 192 && render.stopped == nil)
        #expect(voice.state == .playing && voice.position == 192 && voice.underrunFrames == 64)
    }

    @Test
    func backingRenderWithoutAnyBlockIsOneSilenceRun() throws {
        var voice = try Self.playing(Self.spec())
        let render = try voice.render(frames: 30, at: Self.sample(7))
        #expect(render.segments == [.silence(sourceFrame: 0, frames: 30)])
        #expect(Self.events(render) == [Self.event("underrun", 7, 30)])
        #expect(voice.underrunFrames == 30 && voice.position == 30)
    }

    @Test
    func backingSilencePolicyNeverStopsTheVoice() throws {
        var voice = try Self.playing(Self.spec(underrun: .silenceAndReport))
        for round in 0..<3 {
            let render = try voice.render(frames: 100, at: Self.sample(Int64(round) * 100))
            #expect(render.stopped == nil && render.renderedFrames == 100)
        }
        #expect(voice.state == .playing && voice.underrunFrames == 300 && voice.position == 300)
    }

    @Test
    func backingRenderLengthBounds() throws {
        var voice = try Self.playing(Self.spec())
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.prefetch(.renderLengthOutOfRange(frames: 0, maximum: 256))) {
            try voice.render(frames: 0, at: Self.sample(0))
        }
        #expect(throws: BackingClipRefusal.prefetch(.renderLengthOutOfRange(frames: 257, maximum: 256))) {
            try voice.render(frames: 257, at: Self.sample(0))
        }
        #expect(throws: BackingClipRefusal.prefetch(.renderLengthOutOfRange(frames: -1, maximum: 256))) {
            try voice.render(frames: -1, at: Self.sample(0))
        }
        #expect(voice.snapshot == before)
        #expect(try voice.render(frames: 1, at: Self.sample(0)).renderedFrames == 1)
        #expect(try voice.render(frames: 256, at: Self.sample(1)).renderedFrames == 256)
        #expect(voice.position == 257)
    }

    @Test
    func backingRenderSampleStampOverflowBounds() throws {
        var voice = try Self.playing(Self.spec())
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.prefetch(.frameOverflow(startFrame: Int64.max - 9, frames: 10))) {
            try voice.render(frames: 10, at: Self.sample(Int64.max - 9))
        }
        #expect(voice.snapshot == before)
        let render = try voice.render(frames: 10, at: Self.sample(Int64.max - 10))
        #expect(Self.events(render) == [Self.event("underrun", Int64.max - 10, 10)])
        var shortLoop = try Self.playing(Self.spec(loop: BackingClipLoop(startFrame: 0, endFrame: 5)))
        #expect(throws: BackingClipRefusal.prefetch(.frameOverflow(startFrame: Int64.max - 9, frames: 10))) {
            try shortLoop.render(frames: 10, at: Self.sample(Int64.max - 9))
        }
    }

    @Test
    func backingRenderIsRefusedUnlessPlaying() throws {
        var disarmed = try Self.voice(Self.spec())
        var armed = try Self.armed(Self.spec())
        let before = armed.snapshot
        #expect(throws: BackingClipRefusal.notPlaying(.disarmed)) { try disarmed.render(frames: 1, at: Self.sample(0)) }
        #expect(throws: BackingClipRefusal.notPlaying(.armed)) { try armed.render(frames: 1, at: Self.sample(0)) }
        #expect(armed.snapshot == before)
    }

    @Test
    func backingRenderRefusalOrderIsStateThenLengthThenOverflowThenLoop() throws {
        var stopped = try Self.voice(Self.spec())
        try stopped.stop()
        #expect(throws: BackingClipRefusal.voiceStopped(.requested)) {
            try stopped.render(frames: 0, at: Self.sample(0))
        }
        var disarmed = try Self.voice(Self.spec())
        #expect(throws: BackingClipRefusal.notPlaying(.disarmed)) { try disarmed.render(frames: 0, at: Self.sample(0)) }
        let loop = BackingClipLoop(startFrame: 0, endFrame: 10)
        var looped = try Self.playing(Self.spec(loop: loop))
        #expect(throws: BackingClipRefusal.prefetch(.renderLengthOutOfRange(frames: 300, maximum: 256))) {
            try looped.render(frames: 300, at: Self.sample(Int64.max))
        }
        #expect(throws: BackingClipRefusal.prefetch(.frameOverflow(startFrame: Int64.max, frames: 11))) {
            try looped.render(frames: 11, at: Self.sample(Int64.max))
        }
        #expect(throws: BackingClipRefusal.renderExceedsLoop(frames: 11, loopFrames: 10)) {
            try looped.render(frames: 11, at: Self.sample(0))
        }
    }

    @Test
    func backingClipEndStopsAfterExactlyTheRemainingFrames() throws {
        var voice = try Self.playing(Self.spec(total: 100))
        try voice.insert(Self.block(0))
        try voice.insert(Self.block(64))
        let render = try voice.render(frames: 100, at: Self.sample(0))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64), .served(sourceFrame: 64, frames: 36)])
        #expect(render.renderedFrames == 100 && render.stopped == .reachedEnd && render.discontinuities.isEmpty)
        #expect(voice.state == .stopped(.reachedEnd) && voice.position == 100)
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.voiceStopped(.reachedEnd)) {
            try voice.render(frames: 1, at: Self.sample(0))
        }
        #expect(voice.snapshot == before)
    }

    @Test
    func backingClipEndNeverRendersFramesPastTheEnd() throws {
        var voice = try Self.playing(Self.spec(total: 100))
        try voice.insert(Self.block(0))
        try voice.insert(Self.block(64))
        let render = try voice.render(frames: 101, at: Self.sample(0))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64), .served(sourceFrame: 64, frames: 36)])
        #expect(render.renderedFrames == 100 && render.stopped == .reachedEnd)
        #expect(render.outcome == .reachedEnd(unrenderedFrames: 1))
        #expect(voice.position == 100)
    }

    @Test
    func backingClipEndBoundsNearInt64MaxNeverComputeTotalPlusOne() throws {
        let total = Int64.max
        #expect(try Self.spec(total: total).totalFrames == total)
        for (frames, outcome, rendered) in [(1, BackingRenderOutcome.complete, 1),
                                            (2, .reachedEnd(unrenderedFrames: 0), 2),
                                            (3, .reachedEnd(unrenderedFrames: 1), 2)] {
            var voice = try Self.playing(Self.spec(total: total))
            try voice.seek(to: total - 2)
            let render = try voice.render(frames: frames, at: Self.sample(0))
            #expect(render.outcome == outcome && render.renderedFrames == rendered)
            #expect(render.stopped == (outcome == .complete ? nil : .reachedEnd))
            #expect(voice.position == (outcome == .complete ? total - 1 : total))
        }
        var edge = try Self.playing(Self.spec(total: total))
        let before = edge.snapshot
        #expect(throws: BackingClipRefusal.seekOutOfRange(frame: total, totalFrames: total)) {
            try edge.seek(to: total)
        }
        #expect(edge.snapshot == before)
        try edge.seek(to: total - 1)
        #expect(edge.position == total - 1)
    }

    @Test
    func backingLoopNearInt64MaxWrapsAtTheLoopEnd() throws {
        let loop = BackingClipLoop(startFrame: Int64.max - 5, endFrame: Int64.max)
        var voice = try Self.playing(Self.spec(total: Int64.max, loop: loop))
        try voice.seek(to: Int64.max - 3)
        let render = try voice.render(frames: 4, at: Self.sample(0))
        #expect(render.outcome == .loopWrapped(unrenderedFrames: 1) && render.renderedFrames == 3)
        #expect(voice.position == Int64.max - 5 && voice.state == .playing)
    }

    @Test
    func backingClipEndOneFrameShortKeepsPlaying() throws {
        var voice = try Self.playing(Self.spec(total: 100))
        try voice.insert(Self.block(0))
        try voice.insert(Self.block(64))
        let first = try voice.render(frames: 99, at: Self.sample(0))
        #expect(first.renderedFrames == 99 && first.stopped == nil && voice.state == .playing)
        let last = try voice.render(frames: 2, at: Self.sample(99))
        #expect(last.segments == [.served(sourceFrame: 99, frames: 1)])
        #expect(last.renderedFrames == 1 && last.stopped == .reachedEnd)
    }

    @Test
    func backingSingleFrameClipPlaysOneFrameThenStops() throws {
        var voice = try Self.playing(Self.spec(total: 1))
        try voice.insert(Self.block(0, 1))
        let render = try voice.render(frames: 5, at: Self.sample(0))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 1)] && render.renderedFrames == 1)
        #expect(voice.state == .stopped(.reachedEnd) && voice.position == 1)
    }

    @Test
    func backingSeekWhilePlayingReportsOneLocateAtTheNextRender() throws {
        var voice = try Self.playing(Self.spec())
        try voice.insert(Self.block(0))
        _ = try voice.render(frames: 10, at: Self.sample(0))
        try voice.seek(to: 700)
        #expect(voice.state == .playing)
        try voice.insert(Self.block(700, read: 2))
        let first = try voice.render(frames: 64, at: Self.sample(2000))
        #expect(Self.events(first) == [Self.event("locate", 2000)])
        #expect(first.segments == [.served(sourceFrame: 700, frames: 64)])
        #expect(!voice.hasPendingLocate)
        let second = try voice.render(frames: 4, at: Self.sample(2064))
        #expect(Self.events(second) == [Self.event("underrun", 2064, 4)])
    }

    @Test
    func backingLocateAndUnderrunShareTheFirstFrameInOrder() throws {
        var voice = try Self.playing(Self.spec())
        try voice.seek(to: 10)
        let render = try Self.rendered(&voice, 4, at: 40)
        #expect(Self.events(render) == [Self.event("locate", 40), Self.event("underrun", 40, 4)])
    }

    @Test
    func backingLocateSurvivesARefusedRender() throws {
        var voice = try Self.playing(Self.spec())
        try voice.seek(to: 10)
        #expect(throws: BackingClipRefusal.prefetch(.renderLengthOutOfRange(frames: 0, maximum: 256))) {
            try voice.render(frames: 0, at: Self.sample(0))
        }
        #expect(voice.hasPendingLocate)
    }

    @Test
    func backingIdenticalInputsGiveIdenticalRenders() throws {
        struct Run: Equatable {
            let segments: [PrefetchSegment]
            let events: [Event]
            let snapshot: BackingVoiceSnapshot
        }
        func run() throws -> Run {
            var voice = try Self.playing(Self.spec())
            try voice.insert(Self.block(0))
            try voice.insert(Self.block(128))
            let render = try voice.render(frames: 192, at: Self.sample(9))
            return Run(segments: render.segments, events: Self.events(render), snapshot: voice.snapshot)
        }
        let first = try run()
        let second = try run()
        #expect(first == second)
        #expect(first.segments == [.served(sourceFrame: 0, frames: 64), .silence(sourceFrame: 64, frames: 64),
                                   .served(sourceFrame: 128, frames: 64)])
    }

    static func rendered(_ voice: inout BackingClipVoice, _ frames: Int, at frame: Int64) throws -> BackingRender {
        try voice.render(frames: frames, at: sample(frame))
    }
}
