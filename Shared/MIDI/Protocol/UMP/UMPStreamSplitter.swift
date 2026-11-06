/// Splits a bounded batch of UMP words into checked packets, in input order.
///
/// Framing reads only the Message Type nibble of each packet's first word; it never inspects values and never infers
/// the effective protocol (media-contract §9.1). Every type, reserved ones included, is kept as an opaque packet with
/// its words unchanged. A batch that ends inside a packet is refused whole: no packets are returned.
struct UMPStreamSplitter: Equatable, Sendable {
    /// The largest bound a splitter accepts.
    static let maximumWordsLimit = 1 << 20
    /// The bound of `standard`.
    static let defaultMaximumWords = 4096
    static let standard = UMPStreamSplitter(validatedMaximumWords: defaultMaximumWords)

    private let storedMaximumWords: Int

    private init(validatedMaximumWords: Int) {
        storedMaximumWords = validatedMaximumWords
    }

    /// Refuses a bound outside 1...`maximumWordsLimit`.
    init(maximumWords: Int) throws(UMPRefusal) {
        guard (1...Self.maximumWordsLimit).contains(maximumWords) else {
            throw .valueOutOfRange(field: .batchLimit, value: maximumWords)
        }
        self.init(validatedMaximumWords: maximumWords)
    }

    /// The most words one `split` call accepts.
    var maximumWords: Int { storedMaximumWords }

    func split(_ words: [UInt32]) throws(UMPRefusal) -> [UMPPacket] {
        guard words.count <= storedMaximumWords else {
            throw .batchTooLarge(count: words.count, limit: storedMaximumWords)
        }
        var packets: [UMPPacket] = []
        var start = 0
        while start < words.count {
            let type = UMPMessageType(firstWord: words[start])
            let remaining = words.count - start
            guard remaining >= type.wordCount else {
                throw .truncated(mt: type, have: remaining, need: type.wordCount)
            }
            let end = start + type.wordCount
            packets.append(try UMPPacket(words: Array(words[start..<end])))
            start = end
        }
        return packets
    }
}
