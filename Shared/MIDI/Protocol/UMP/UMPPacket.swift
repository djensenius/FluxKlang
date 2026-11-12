/// A UMP Group, 0...15 (shown to users as 1...16).
struct UMPGroup: Equatable, Hashable, Sendable {
    private let storedValue: UInt8

    init(_ value: UInt8) throws(UMPRefusal) {
        guard value < 16 else { throw .valueOutOfRange(field: .group, value: Int(value)) }
        storedValue = value
    }

    var value: UInt8 { storedValue }
}

/// A UMP channel nibble, 0...15 (`MIDI1Semantic` numbers the same channel 1...16).
struct UMPChannel: Equatable, Hashable, Sendable {
    private let storedValue: UInt8

    init(_ value: UInt8) throws(UMPRefusal) {
        guard value < 16 else { throw .valueOutOfRange(field: .channel, value: Int(value)) }
        storedValue = value
    }

    var value: UInt8 { storedValue }
}

/// A 7-bit field (note number, controller index, bank, program), 0...127.
struct UMPSevenBit: Equatable, Hashable, Sendable {
    private let storedValue: UInt8

    init(_ value: UInt8) throws(UMPRefusal) {
        guard value < 0x80 else { throw .valueOutOfRange(field: .sevenBit, value: Int(value)) }
        storedValue = value
    }

    var value: UInt8 { storedValue }
}

/// One checked Universal MIDI Packet: its word count always matches the Message Type in its first word.
/// The words are kept exactly as received, including reserved types and reserved bits.
struct UMPPacket: Equatable, Sendable {
    private let storedWords: [UInt32]

    private init(validatedWords: [UInt32]) {
        storedWords = validatedWords
    }

    /// Refuses an empty array or a word count that differs from the first word's Message Type.
    init(words: [UInt32]) throws(UMPRefusal) {
        guard let first = words.first else { throw .emptyPacket }
        let type = UMPMessageType(firstWord: first)
        guard words.count == type.wordCount else {
            throw .wrongWordCount(mt: type, have: words.count, need: type.wordCount)
        }
        self.init(validatedWords: words)
    }

    /// An MT 0x1 packet; the top nibble is forced to 0x1, so the result is always well formed.
    static func system(_ word: UInt32) -> UMPPacket {
        UMPPacket(validatedWords: [(word & 0x0FFF_FFFF) | 0x1000_0000])
    }

    /// An MT 0x2 packet; the top nibble is forced to 0x2, so the result is always well formed.
    static func midi1ChannelVoice(_ word: UInt32) -> UMPPacket {
        UMPPacket(validatedWords: [(word & 0x0FFF_FFFF) | 0x2000_0000])
    }

    /// An MT 0x3 packet; the top nibble is forced to 0x3, so the result is always well formed.
    static func data64(_ first: UInt32, _ second: UInt32) -> UMPPacket {
        UMPPacket(validatedWords: [(first & 0x0FFF_FFFF) | 0x3000_0000, second])
    }

    /// An MT 0x4 packet; the top nibble is forced to 0x4, so the result is always well formed.
    static func midi2ChannelVoice(_ first: UInt32, _ second: UInt32) -> UMPPacket {
        UMPPacket(validatedWords: [(first & 0x0FFF_FFFF) | 0x4000_0000, second])
    }

    var words: [UInt32] { storedWords }

    var messageType: UMPMessageType { UMPMessageType(firstWord: storedWords[0]) }

    /// The Group nibble, or nil for types that carry none (`UMPMessageType.carriesGroup`).
    var group: UMPGroup? {
        guard messageType.carriesGroup else { return nil }
        return try? UMPGroup(UInt8((storedWords[0] >> 24) & 0x0F))
    }
}
