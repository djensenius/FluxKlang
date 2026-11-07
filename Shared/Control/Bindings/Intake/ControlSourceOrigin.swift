/// An opaque, caller-chosen name of the sending source, for example `lcxl-1`. Intake never derives it from a device,
/// endpoint or clock. Valid: 1...32 UTF-8 bytes, each `a...z`, `0...9` or `-`, so the `.` separator of a source ID can
/// never occur inside a token. Ordering compares UTF-8 bytes.
struct ControlSourceOrigin: Hashable, Comparable, Sendable {
    let token: String

    /// Throws `.invalidOrigin(length:)` for a bad byte count first, then `.invalidOriginByte(offset:)` for the first
    /// bad byte.
    init(_ token: String) throws(ControlIntakeRefusal) {
        let count = token.utf8.count
        guard ControlIntakeBounds.originByteRange.contains(count) else { throw .invalidOrigin(length: count) }
        for (offset, byte) in token.utf8.enumerated() where !Self.isAllowed(byte) {
            throw .invalidOriginByte(offset: offset)
        }
        self.token = token
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.token.utf8.lexicographicallyPrecedes(rhs.token.utf8)
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }
}
