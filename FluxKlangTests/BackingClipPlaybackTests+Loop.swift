import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension BackingClipPlaybackTests {
    /// A looping voice over `[0, 200)` playing at frame 192, eight frames before the loop end, with an empty pool.
    static func voiceNearLoopEnd(underrun: BackingUnderrunPolicy = .silenceAndReport,
                                 read: UInt64 = 1) throws -> BackingClipVoice {
        let loop = BackingClipLoop(startFrame: 0, endFrame: 200)
        var voice = try playing(spec(loop: loop, underrun: underrun), read: read)
        for start in [Int64(0), 64, 128] { try voice.insert(block(start, read: read)) }
        let render = try voice.render(frames: 192, at: sample(0))
        #expect(render.renderedFrames == 192 && render.discontinuities.isEmpty)
        try voice.insert(block(192, 8, read: read))
        return voice
    }

    @Test
    func backingLoopOneFrameBeforeTheEndDoesNotWrap() throws {
        var voice = try Self.voiceNearLoopEnd()
        let render = try voice.render(frames: 7, at: Self.sample(1000))
        #expect(render.segments == [.served(sourceFrame: 192, frames: 7)] && render.discontinuities.isEmpty)
        #expect(voice.position == 199 && voice.readGeneration == 1 && voice.state == .playing)
    }

    @Test
    func backingLoopWrapsEagerlyWhenARenderEndsExactlyAtTheLoopEnd() throws {
        var voice = try Self.voiceNearLoopEnd()
        let render = try voice.render(frames: 8, at: Self.sample(1000))
        #expect(render.segments == [.served(sourceFrame: 192, frames: 8)] && render.renderedFrames == 8)
        #expect(Self.events(render) == [Self.event("loopWrap", 1008)])
        #expect(voice.position == 0 && voice.readGeneration == 2 && voice.residentBlocks.isEmpty)
        #expect(voice.state == .playing && !voice.hasPendingLocate)
    }

    @Test
    func backingLoopOneFramePastTheEndIsTruncatedAtTheEndWithoutAnUnderrun() throws {
        var voice = try Self.voiceNearLoopEnd()
        let render = try voice.render(frames: 9, at: Self.sample(1000))
        #expect(render.segments == [.served(sourceFrame: 192, frames: 8)] && render.renderedFrames == 8)
        #expect(Self.events(render) == [Self.event("loopWrap", 1008)])
        #expect(render.outcome == .loopWrapped(unrenderedFrames: 1) && render.stopped == nil)
        #expect(render.readGeneration == 2 && render.readGeneration == voice.readGeneration)
        #expect(voice.position == 0 && voice.underrunFrames == 0)
        #expect(voice.state == .playing && voice.residentBlocks.isEmpty)
    }

    @Test
    func backingLoopRefillWithTheNewReadGenerationPlaysTheLoopHeadWithoutUnderrun() throws {
        var voice = try Self.voiceNearLoopEnd()
        let wrapped = try voice.render(frames: 9, at: Self.sample(1000))
        #expect(wrapped.outcome == .loopWrapped(unrenderedFrames: 1))
        try voice.insert(Self.block(0, read: 2))
        let render = try voice.render(frames: 64, at: Self.sample(1008))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64)] && render.discontinuities.isEmpty)
        #expect(render.outcome == .complete && voice.underrunFrames == 0 && voice.position == 64)
        #expect(render.readGeneration == 2)
    }

    @Test
    func backingLoopHeadNotRefilledAfterTheWrapUnderrunsAtTheLoopStart() throws {
        var voice = try Self.voiceNearLoopEnd()
        _ = try voice.render(frames: 8, at: Self.sample(1000))
        let render = try voice.render(frames: 5, at: Self.sample(1008))
        #expect(render.segments == [.silence(sourceFrame: 0, frames: 5)])
        #expect(Self.events(render) == [Self.event("underrun", 1008, 5)] && voice.underrunFrames == 5)
    }

    @Test
    func backingLoopChunkingDoesNotChangeServedFramesOrDiscontinuities() throws {
        struct Trace: Equatable {
            let frames: [Int64]
            let events: [Event]
        }
        func refill(_ voice: inout BackingClipVoice) throws {
            for start in stride(from: Int64(0), to: 256, by: 64) {
                try voice.insert(Self.block(start, read: voice.readGeneration))
            }
        }
        func trace(chunk: Int) throws -> Trace {
            var voice = try Self.playing(Self.spec(loop: BackingClipLoop(startFrame: 0, endFrame: 256)))
            try refill(&voice)
            var frames: [Int64] = []
            var events: [Event] = []
            var produced = 0
            while produced < 600 {
                let render = try voice.render(frames: min(chunk, 600 - produced), at: Self.sample(Int64(produced)))
                for case .served(let start, let count) in render.segments { frames += start..<(start + Int64(count)) }
                events += Self.events(render)
                produced += render.renderedFrames
                if case .loopWrapped = render.outcome { try refill(&voice) }
            }
            return Trace(frames: frames, events: events)
        }
        let expected = Trace(frames: Array(0..<256) + Array(0..<256) + Array(0..<88),
                             events: [Self.event("loopWrap", 256), Self.event("loopWrap", 512)])
        for chunk in [1, 3, 7, 256] {
            let result = try trace(chunk: chunk)
            #expect(result == expected)
        }
    }

    @Test
    func backingLoopWrapDropsBlocksBeyondTheLoopEnd() throws {
        var voice = try Self.voiceNearLoopEnd()
        try voice.insert(Self.block(200, 64))
        let discarded = voice.snapshot.discardedStaleBlocks
        _ = try voice.render(frames: 8, at: Self.sample(0))
        #expect(voice.residentBlocks.isEmpty && voice.snapshot.discardedStaleBlocks == discarded + 1)
    }

    @Test
    func backingRenderMayBeAsLongAsTheLoopButNotLonger() throws {
        let loop = BackingClipLoop(startFrame: 0, endFrame: 200)
        var voice = try Self.playing(Self.spec(loop: loop))
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.renderExceedsLoop(frames: 201, loopFrames: 200)) {
            try voice.render(frames: 201, at: Self.sample(0))
        }
        #expect(voice.snapshot == before)
        for start in [Int64(0), 64, 128] { try voice.insert(Self.block(start)) }
        try voice.insert(Self.block(192, 8))
        let render = try voice.render(frames: 200, at: Self.sample(0))
        #expect(render.renderedFrames == 200 && render.discontinuities.count == 1)
        #expect(Self.events(render) == [Self.event("loopWrap", 200)] && voice.position == 0)
    }

    @Test
    func backingOneFrameLoopAcceptsOneFrameAndRefusesTwo() throws {
        let loop = BackingClipLoop(startFrame: 5, endFrame: 6)
        var voice = try Self.playing(Self.spec(loop: loop))
        try voice.seek(to: 5)
        try voice.insert(Self.block(5, 1, read: 2))
        #expect(throws: BackingClipRefusal.renderExceedsLoop(frames: 2, loopFrames: 1)) {
            try voice.render(frames: 2, at: Self.sample(0))
        }
        let render = try voice.render(frames: 1, at: Self.sample(0))
        #expect(render.segments == [.served(sourceFrame: 5, frames: 1)])
        #expect(Self.events(render) == [Self.event("locate", 0), Self.event("loopWrap", 1)])
        #expect(voice.position == 5 && voice.readGeneration == 3)
    }

    @Test
    func backingLocateThenWrapKeepOutputOrderAndTruncateTheRemainder() throws {
        let loop = BackingClipLoop(startFrame: 0, endFrame: 200)
        var voice = try Self.playing(Self.spec(loop: loop))
        try voice.seek(to: 199)
        try voice.insert(Self.block(199, 1, read: 2))
        let render = try voice.render(frames: 3, at: Self.sample(10))
        #expect(Self.events(render) == [Self.event("locate", 10), Self.event("loopWrap", 11)])
        #expect(render.segments == [.served(sourceFrame: 199, frames: 1)])
        #expect(render.outcome == .loopWrapped(unrenderedFrames: 2) && voice.underrunFrames == 0)
    }

    @Test
    func backingPositionPastTheLoopEndPlaysToTheClipEnd() throws {
        let loop = BackingClipLoop(startFrame: 0, endFrame: 200)
        var voice = try Self.playing(Self.spec(loop: loop))
        try voice.seek(to: 900)
        try voice.insert(Self.block(900, 64, read: 2))
        try voice.insert(Self.block(964, 64, read: 2))
        let render = try voice.render(frames: 100, at: Self.sample(0))
        #expect(render.stopped == .reachedEnd && render.renderedFrames == 100)
        #expect(Self.events(render) == [Self.event("locate", 0)])
        #expect(voice.state == .stopped(.reachedEnd) && voice.position == 1000)
    }

    @Test
    func backingLoopEndingAtTheClipEndWrapsInsteadOfStopping() throws {
        let loop = BackingClipLoop(startFrame: 800, endFrame: 1000)
        var voice = try Self.playing(Self.spec(loop: loop))
        try voice.seek(to: 900)
        try voice.insert(Self.block(900, 64, read: 2))
        try voice.insert(Self.block(964, 36, read: 2))
        let render = try voice.render(frames: 100, at: Self.sample(0))
        #expect(render.stopped == nil && render.renderedFrames == 100)
        #expect(Self.events(render) == [Self.event("locate", 0), Self.event("loopWrap", 100)])
        #expect(voice.state == .playing && voice.position == 800 && voice.readGeneration == 3)
    }

    @Test
    func backingStopVoiceWrapsAtTheLoopEndAndDoesNotCountTheRemainderAsAnUnderrun() throws {
        var voice = try Self.voiceNearLoopEnd(underrun: .stopVoice)
        let render = try voice.render(frames: 9, at: Self.sample(1000))
        #expect(render.segments == [.served(sourceFrame: 192, frames: 8)] && render.renderedFrames == 8)
        #expect(Self.events(render) == [Self.event("loopWrap", 1008)])
        #expect(render.stopped == nil && render.outcome == .loopWrapped(unrenderedFrames: 1))
        #expect(voice.position == 0 && voice.state == .playing && voice.underrunFrames == 0)
        let next = try voice.render(frames: 1, at: Self.sample(1008))
        #expect(next.stopped == .underrun && voice.state == .stopped(.underrun))
    }

    @Test
    func backingWrapIsRefusedBeforeServingWhenTheReadGenerationCannotAdvance() throws {
        var voice = try Self.voiceNearLoopEnd(read: UInt64.max)
        let before = voice.snapshot
        for frames in [8, 9] {
            #expect(throws: BackingClipRefusal.prefetch(.generationOverflow)) {
                try voice.render(frames: frames, at: Self.sample(0))
            }
            #expect(voice.snapshot == before && voice.state == .playing)
        }
        #expect(try voice.render(frames: 7, at: Self.sample(0)).renderedFrames == 7)
    }

    @Test
    func backingWrapAtTheLastReadGenerationBelowTheMaximumSucceedsThenSeekRefuses() throws {
        var voice = try Self.voiceNearLoopEnd(read: UInt64.max - 1)
        _ = try voice.render(frames: 8, at: Self.sample(0))
        #expect(voice.readGeneration == UInt64.max && voice.position == 0)
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.prefetch(.generationOverflow)) { try voice.seek(to: 5) }
        #expect(voice.snapshot == before && !voice.hasPendingLocate)
    }

    @Test
    func backingSeekIsRefusedAtTheMaximumReadGenerationAndAllowedOneBelow() throws {
        var exhausted = try Self.playing(Self.spec(), read: UInt64.max)
        let before = exhausted.snapshot
        #expect(throws: BackingClipRefusal.prefetch(.generationOverflow)) { try exhausted.seek(to: 5) }
        #expect(exhausted.snapshot == before)
        var last = try Self.playing(Self.spec(), read: UInt64.max - 1)
        try last.seek(to: 5)
        #expect(last.readGeneration == UInt64.max && last.position == 5)
    }

    @Test
    func backingSeekToExactlyTheLoopEndPlaysOnWithoutWrapping() throws {
        let loop = BackingClipLoop(startFrame: 0, endFrame: 200)
        var voice = try Self.playing(Self.spec(loop: loop))
        try voice.seek(to: 200)
        try voice.insert(Self.block(200, 64, read: 2))
        try voice.insert(Self.block(264, 64, read: 2))
        let render = try voice.render(frames: 100, at: Self.sample(0))
        #expect(render.outcome == .complete && render.renderedFrames == 100)
        #expect(Self.events(render) == [Self.event("locate", 0)])
        #expect(voice.state == .playing && voice.position == 300 && voice.readGeneration == 2)
    }

    @Test
    func backingSeekToTheLoopEndBeforeTheClipEndPlaysOnToTheClipEndWithoutWrapping() throws {
        let loop = BackingClipLoop(startFrame: 0, endFrame: 200)
        var voice = try Self.playing(Self.spec(total: 300, loop: loop))
        try voice.seek(to: 200)
        try voice.insert(Self.block(200, 64, read: 2))
        try voice.insert(Self.block(264, 36, read: 2))
        let render = try voice.render(frames: 100, at: Self.sample(0))
        #expect(render.outcome == .reachedEnd(unrenderedFrames: 0) && render.stopped == .reachedEnd)
        #expect(Self.events(render) == [Self.event("locate", 0)])
        #expect(voice.state == .stopped(.reachedEnd) && voice.position == 300 && voice.readGeneration == 2)
    }
}
