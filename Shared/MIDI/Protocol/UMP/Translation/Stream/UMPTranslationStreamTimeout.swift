/// How long `UMPTranslationStream` waits after holding a Data Entry MSB (CC 6) for its LSB (CC 38) before it sends
/// the CC 6 alone: 1 ms through 100 ms inclusive, in nanoseconds. `standard` is 5 ms (#362 owner ruling).
///
/// Built only through `make(nanoseconds:)`, so every value is in range.
struct UMPTranslationStreamTimeout: Hashable, Sendable {
    /// 1 ms through 100 ms inclusive.
    static let allowedNanoseconds: ClosedRange<UInt64> = 1_000_000...100_000_000

    /// 5 ms.
    static let standard = UMPTranslationStreamTimeout(nanoseconds: 5_000_000)

    let nanoseconds: UInt64

    private init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    static func make(nanoseconds: UInt64) throws(UMPTranslationStreamRefusal) -> UMPTranslationStreamTimeout {
        guard allowedNanoseconds.contains(nanoseconds) else { throw .timeoutOutOfRange(nanoseconds: nanoseconds) }
        return UMPTranslationStreamTimeout(nanoseconds: nanoseconds)
    }
}
