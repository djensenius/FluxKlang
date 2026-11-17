/// The time source of `UMPTranslationStreamDriver`: monotonic nanoseconds, the clock `UMPTranslationStream` is given.
/// A live adapter converts host ticks; tests inject a settable fake.
protocol UMPTranslationStreamClock: Sendable {
    func nowNanoseconds() -> UInt64
}
