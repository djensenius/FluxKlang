//
//  MIDIInternalClockWindow.swift
//  FluxKlang
//
//  One render window of a sample clock that the internal clock plans messages for (#84).
//

/// A bounded run of frames `[startFrame, endFrame)` on one sample-clock generation.
///
/// The window names the sample-clock generation it belongs to, so a plan can refuse a map of another
/// generation. It is created only by `make`, which bounds the lookahead and the frame arithmetic.
struct MIDIInternalClockWindow: Equatable, Sendable {
    let sampleGeneration: Generation
    let startFrame: Int64
    let frameCount: Int64
    /// Exclusive: `startFrame + frameCount`, never past `Int64.max`.
    let endFrame: Int64

    private init(sampleGeneration: Generation, startFrame: Int64, frameCount: Int64, endFrame: Int64) {
        self.sampleGeneration = sampleGeneration
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.endFrame = endFrame
    }

    /// A window of `1...MIDIInternalClockPlan.maximumLookaheadFrames` frames whose end does not overflow.
    static func make(sampleGeneration: Generation, startFrame: Int64, frameCount: Int64)
        throws(MIDIInternalClockError) -> MIDIInternalClockWindow {
        let (endFrame, overflow) = startFrame.addingReportingOverflow(frameCount)
        guard (1...MIDIInternalClockPlan.maximumLookaheadFrames).contains(frameCount), !overflow else {
            throw .windowOutOfRange(startFrame: startFrame, frameCount: frameCount)
        }
        return MIDIInternalClockWindow(sampleGeneration: sampleGeneration, startFrame: startFrame,
                                       frameCount: frameCount, endFrame: endFrame)
    }
}
