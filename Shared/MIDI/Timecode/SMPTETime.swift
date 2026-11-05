/// A validated SMPTE timecode label at one MTC rate.
struct SMPTETime: Equatable, Hashable, Sendable {
    let hours: Int
    let minutes: Int
    let seconds: Int
    let frames: Int
    let rate: SMPTEFrameRate

    init(hours: Int, minutes: Int, seconds: Int, frames: Int, rate: SMPTEFrameRate) throws(TimecodeError) {
        guard (0...23).contains(hours) else { throw .fieldOutOfRange(.hours, value: hours) }
        guard (0...59).contains(minutes) else { throw .fieldOutOfRange(.minutes, value: minutes) }
        guard (0...59).contains(seconds) else { throw .fieldOutOfRange(.seconds, value: seconds) }
        guard (0..<rate.framesPerSecond).contains(frames) else { throw .fieldOutOfRange(.frames, value: frames) }
        if rate.isDropFrame, seconds == 0, frames < 2, minutes % 10 != 0 {
            throw .droppedFrameLabel(minutes: minutes, frames: frames)
        }
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.rate = rate
    }

    /// Converts a zero-based frame count since 00:00:00:00 into its label.
    init(frameCount: Int, rate: SMPTEFrameRate) throws(TimecodeError) {
        guard (0..<rate.framesPerDay).contains(frameCount) else {
            throw .frameCountOutOfRange(frameCount, framesPerDay: rate.framesPerDay)
        }
        var labelIndex = frameCount
        if rate.isDropFrame {
            let tens = frameCount / SMPTEFrameRate.dropFramesPerTenMinutes
            let remainder = frameCount % SMPTEFrameRate.dropFramesPerTenMinutes
            // The first minute of each ten keeps all 1800 labels; each later minute starts two labels late.
            let skippedMinutes = remainder < 2 ? 0 : (remainder - 2) / SMPTEFrameRate.dropFramesPerMinute
            labelIndex += 18 * tens + 2 * skippedMinutes
        }
        let fps = rate.framesPerSecond
        let totalSeconds = labelIndex / fps
        try self.init(hours: totalSeconds / 3600, minutes: totalSeconds / 60 % 60, seconds: totalSeconds % 60,
                      frames: labelIndex % fps, rate: rate)
    }

    /// Zero-based frame count since 00:00:00:00, excluding dropped labels.
    var frameCount: Int {
        let totalMinutes = hours * 60 + minutes
        let labelIndex = ((totalMinutes * 60) + seconds) * rate.framesPerSecond + frames
        guard rate.isDropFrame else { return labelIndex }
        return labelIndex - 2 * (totalMinutes - totalMinutes / 10)
    }

    /// Offsets by whole frames, wrapping around the 24-hour day as MTC does.
    func adding(frames offset: Int) -> Self {
        let day = rate.framesPerDay
        let wrapped = ((frameCount + offset % day) % day + day) % day
        // A wrapped count is always in range, so this cannot refuse; fall back to self defensively.
        return (try? Self(frameCount: wrapped, rate: rate)) ?? self
    }
}
