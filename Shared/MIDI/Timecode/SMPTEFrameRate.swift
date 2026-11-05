/// The four MTC rate codes. Raw values are the two-bit codes carried by quarter-frame piece 7,
/// the full-frame hours byte and the MMC standard time code hours byte.
/// 29.97 non-drop has no MTC code and is intentionally absent.
enum SMPTEFrameRate: UInt8, CaseIterable, Equatable, Hashable, Sendable {
    case fps24 = 0
    case fps25 = 1
    /// 29.97 drop-frame ("30 drop").
    case fps2997DropFrame = 2
    case fps30 = 3

    init(code: UInt8) throws(TimecodeError) {
        guard let rate = Self(rawValue: code) else { throw .invalidRateCode(code) }
        self = rate
    }

    /// Nominal frames per labelled second; frame labels run 0..<framesPerSecond.
    var framesPerSecond: Int {
        switch self {
        case .fps24: 24
        case .fps25: 25
        case .fps2997DropFrame, .fps30: 30
        }
    }

    var isDropFrame: Bool { self == .fps2997DropFrame }

    /// Distinct timecode labels in one 24-hour day.
    var framesPerDay: Int {
        isDropFrame ? 24 * 6 * Self.dropFramesPerTenMinutes : 24 * 3600 * framesPerSecond
    }

    static let dropFramesPerMinute = 30 * 60 - 2
    static let dropFramesPerTenMinutes = 30 * 600 - 9 * 2
}
