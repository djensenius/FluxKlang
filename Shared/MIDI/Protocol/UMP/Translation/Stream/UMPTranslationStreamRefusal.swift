/// Every refusal from `UMPTranslationStream` and `UMPTranslationStreamTimeout`. A refused call returns nothing and
/// changes nothing.
enum UMPTranslationStreamRefusal: Error, Equatable, Sendable {
    /// The idle timeout is outside `UMPTranslationStreamTimeout.allowedNanoseconds` (1 ms through 100 ms).
    case timeoutOutOfRange(nanoseconds: UInt64)
    /// `got` is earlier than `previous`, the last time this stream accepted. Equal times are accepted.
    case timeWentBackward(previous: UInt64, got: UInt64)
    /// The CC 6 received at `heldAt` would be held until `heldAt + timeoutNanoseconds`, which is past `UInt64.max`.
    case deadlineOverflow(heldAt: UInt64, timeoutNanoseconds: UInt64)
    /// A complete SysEx payload exceeds the stream's inclusive local limit, before byte or time validation.
    case sysExPayloadTooLarge(count: Int, limit: Int)
    /// A wrapped translator, system-message constructor or SysEx7 packetizer refusal.
    case translation(UMPRefusal)
}
