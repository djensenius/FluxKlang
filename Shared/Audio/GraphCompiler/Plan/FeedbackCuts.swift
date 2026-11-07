struct FeedbackCut: Equatable, Sendable {
    let edge: EdgeID
    let channels: Int
    let delayBlocks: Int
    let delayFrames: Int
    let gainCeilingDb: Double

    private init(edge: EdgeID, channels: Int, delayBlocks: Int, delayFrames: Int, gainCeilingDb: Double) {
        self.edge = edge
        self.channels = channels
        self.delayBlocks = delayBlocks
        self.delayFrames = delayFrames
        self.gainCeilingDb = gainCeilingDb
    }

    static func make(
        edge: EdgeID, feedback: EdgeFeedback, channels: Int, blockFrames: Int
    ) throws(RoutingScheduleRefusal) -> FeedbackCut {
        guard feedback.delayBlocks >= 1 else {
            throw .feedbackDelayTooShort(edge, feedback.delayBlocks)
        }
        guard feedback.gainCeilingDb.isFinite, feedback.gainCeilingDb <= 0 else {
            throw .feedbackGainNotCapped(edge)
        }
        guard (1...64).contains(channels), blockFrames > 0 else {
            throw .inconsistentSchedule(.delayLine)
        }
        let (frames, overflow) = feedback.delayBlocks.multipliedReportingOverflow(by: blockFrames)
        guard !overflow else { throw .arithmeticOverflow(.delayFrames) }
        return FeedbackCut(
            edge: edge, channels: channels, delayBlocks: feedback.delayBlocks,
            delayFrames: frames, gainCeilingDb: feedback.gainCeilingDb
        )
    }
}
