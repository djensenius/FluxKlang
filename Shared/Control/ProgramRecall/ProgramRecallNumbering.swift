/// Converts between the internal 0...127 number of a program or a Bank Select part and the number a device shows.
/// Program and each bank part convert on their own; no 14-bit bank number is built. The base is always passed
/// explicitly because devices differ.
enum ProgramRecallNumbering {
    /// Which number a device shows for the internal value 0.
    enum Base: Equatable, Sendable, CaseIterable {
        /// Shows 0...127.
        case zeroBased
        /// Shows 1...128.
        case oneBased
    }

    /// The largest internal value.
    static let maximumInternal = 127

    /// The internal value shown as `displayed`. A zero-based display accepts 0...127 and a one-based display accepts
    /// 1...128; any other `Int` (including `Int.min` and `Int.max`) is refused as `numberOutOfRange(displayed)`. The
    /// range is checked before any arithmetic.
    static func internalValue(displayed: Int, base: Base) throws(ProgramRecallRefusal) -> UInt8 {
        switch base {
        case .zeroBased:
            guard displayed >= 0, displayed <= maximumInternal else { throw .numberOutOfRange(displayed) }
            return UInt8(displayed)
        case .oneBased:
            guard displayed >= 1, displayed <= maximumInternal + 1 else { throw .numberOutOfRange(displayed) }
            return UInt8(displayed - 1)
        }
    }

    /// The number shown for an internal value in 0...127; 128 and above are refused as `numberOutOfRange(value)`.
    static func displayed(internalValue: UInt8, base: Base) throws(ProgramRecallRefusal) -> Int {
        let value = Int(internalValue)
        guard value <= maximumInternal else { throw .numberOutOfRange(value) }
        switch base {
        case .zeroBased:
            return value
        case .oneBased:
            return value + 1
        }
    }
}
