import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension BackingClipPlaybackTests {
    /// A playing `.stopVoice` voice with the given resident blocks (read generation 1), no loop, 1000 frames.
    static func stopVoice(blocks: [PrefetchBlock]) throws -> BackingClipVoice {
        var voice = try playing(spec(underrun: .stopVoice))
        for block in blocks { try voice.insert(block) }
        return voice
    }

    @Test
    func backingStopVoiceWithAGapAtTheFirstFrameStopsWithoutCallingTheRender() throws {
        var voice = try Self.stopVoice(blocks: [Self.block(64)])
        let render = try voice.render(frames: 128, at: Self.sample(10))
        #expect(render.segments.isEmpty && render.renderedFrames == 0 && render.stopped == .underrun)
        #expect(Self.events(render) == [Self.event("underrun", 10, 64)])
        #expect(render.outcome == .underrunStopped(unrenderedFrames: 128))
        #expect(voice.position == 0 && voice.state == .stopped(.underrun) && voice.underrunFrames == 64)
        let kept = try Self.block(64)
        #expect(voice.playhead.underrunFrames == 0 && voice.residentBlocks == [kept])
    }

    @Test
    func backingStopVoiceKeepsOneResidentFrameThenStopsAtTheGap() throws {
        var voice = try Self.stopVoice(blocks: [Self.block(0, 1)])
        let render = try voice.render(frames: 5, at: Self.sample(20))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 1)] && render.renderedFrames == 1)
        #expect(Self.events(render) == [Self.event("underrun", 21, 4)])
        #expect(render.outcome == .underrunStopped(unrenderedFrames: 4) && render.stopped == .underrun)
        #expect(voice.position == 1 && voice.underrunFrames == 4 && voice.playhead.underrunFrames == 0)
    }

    @Test
    func backingStopVoiceGapAtTheVeryEndKeepsAllButTheLastFrame() throws {
        var voice = try Self.stopVoice(blocks: [Self.block(0, 63)])
        let render = try voice.render(frames: 64, at: Self.sample(0))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 63)] && render.renderedFrames == 63)
        #expect(Self.events(render) == [Self.event("underrun", 63, 1)])
        #expect(render.outcome == .underrunStopped(unrenderedFrames: 1))
        #expect(voice.position == 63 && voice.underrunFrames == 1 && voice.playhead.underrunFrames == 0)
    }

    @Test
    func backingStopVoiceReportsTheFullFirstGapNotTheRestOfTheRender() throws {
        var voice = try Self.stopVoice(blocks: [Self.block(0), Self.block(128)])
        let render = try voice.render(frames: 192, at: Self.sample(500))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64)])
        #expect(Self.events(render) == [Self.event("underrun", 564, 64)])
        #expect(render.renderedFrames == 64 && render.stopped == .underrun)
        #expect(render.outcome == .underrunStopped(unrenderedFrames: 128))
        #expect(voice.state == .stopped(.underrun) && voice.position == 64 && voice.underrunFrames == 64)
        let tail = try Self.block(128)
        #expect(voice.residentBlocks == [tail])
        let before = voice.snapshot
        #expect(throws: BackingClipRefusal.voiceStopped(.underrun)) { try voice.render(frames: 1, at: Self.sample(0)) }
        #expect(voice.snapshot == before)
    }

    @Test
    func backingStopVoiceWithoutAGapCommitsTheWholeRenderAndKeepsPlaying() throws {
        var voice = try Self.stopVoice(blocks: [Self.block(0), Self.block(64)])
        let render = try voice.render(frames: 100, at: Self.sample(5))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64), .served(sourceFrame: 64, frames: 36)])
        #expect(render.outcome == .complete && render.stopped == nil && render.discontinuities.isEmpty)
        #expect(voice.state == .playing && voice.position == 100 && voice.underrunFrames == 0)
    }

    @Test
    func backingStopVoiceWithAPendingLocateReportsLocateThenTheUnderrunAtTheSameFrame() throws {
        var voice = try Self.stopVoice(blocks: [])
        try voice.seek(to: 10)
        let render = try voice.render(frames: 4, at: Self.sample(40))
        #expect(Self.events(render) == [Self.event("locate", 40), Self.event("underrun", 40, 4)])
        #expect(voice.position == 10 && voice.state == .stopped(.underrun) && !voice.hasPendingLocate)
    }

    @Test
    func backingStopVoiceNeverLetsThePlayheadCounterPassTheVoiceCounter() throws {
        var voice = try Self.stopVoice(blocks: [Self.block(0, 10)])
        _ = try voice.render(frames: 5, at: Self.sample(0))
        #expect(voice.playhead.underrunFrames <= voice.underrunFrames)
        _ = try voice.render(frames: 20, at: Self.sample(5))
        #expect(voice.playhead.underrunFrames == 0 && voice.underrunFrames == 15)
    }
}
