/// The form of a Flex Data packet, word 0 bits 23...22. Only text packets use forms other than complete.
enum UMPFlexDataForm: UInt8, CaseIterable, Equatable, Sendable {
    /// 0: the whole message is in this packet.
    case complete = 0
    /// 1: the first packet of a message that continues.
    case start = 1
    /// 2: a middle packet.
    case continuation = 2
    /// 3: the last packet.
    case end = 3

    init(bits: UInt32) {
        switch bits & 0x3 {
        case 0: self = .complete
        case 1: self = .start
        case 2: self = .continuation
        default: self = .end
        }
    }
}

/// Status bank 0x01, Metadata Text. Statuses follow bl-midi2-rs (`flex_data.rs`), cmidi2
/// (`cmidi2_flex_data_metadata_text_status`), ALSA alsa-lib `ump_msg.h` and the MIDI 2.0 Workbench. The Workbench
/// also lists 0x0D "Instrument Used", which no other source has; it is refused as `unknownStatus`.
enum UMPFlexDataMetadataText: UInt8, CaseIterable, Equatable, Sendable {
    case unknown = 0x00
    case projectName = 0x01
    case compositionName = 0x02
    case midiClipName = 0x03
    case copyrightNotice = 0x04
    case composerName = 0x05
    case lyricistName = 0x06
    case arrangerName = 0x07
    case publisherName = 0x08
    case primaryPerformerName = 0x09
    case accompanyingPerformerName = 0x0A
    case recordingDate = 0x0B
    case recordingLocation = 0x0C
}

/// Status bank 0x02, Performance Text Events. All sources checked agree on 0x00...0x04.
enum UMPFlexDataPerformanceText: UInt8, CaseIterable, Equatable, Sendable {
    case unknown = 0x00
    case lyrics = 0x01
    case lyricsLanguage = 0x02
    case ruby = 0x03
    case rubyLanguage = 0x04
}

/// The status bank and status of a text packet.
enum UMPFlexDataTextKind: Equatable, Sendable {
    case metadata(UMPFlexDataMetadataText)
    case performance(UMPFlexDataPerformanceText)

    static let metadataBank: UInt8 = 0x01
    static let performanceBank: UInt8 = 0x02

    /// Nil for every other bank, and for statuses the bank doesn't define.
    init?(bank: UInt8, status: UInt8) {
        switch bank {
        case Self.metadataBank:
            guard let text = UMPFlexDataMetadataText(rawValue: status) else { return nil }
            self = .metadata(text)
        case Self.performanceBank:
            guard let text = UMPFlexDataPerformanceText(rawValue: status) else { return nil }
            self = .performance(text)
        default:
            return nil
        }
    }

    /// Word 0 bits 15...8.
    var bank: UInt8 {
        switch self {
        case .metadata: return Self.metadataBank
        case .performance: return Self.performanceBank
        }
    }

    /// Word 0 bits 7...0.
    var status: UInt8 {
        switch self {
        case .metadata(let text): return text.rawValue
        case .performance(let text): return text.rawValue
        }
    }
}

/// One Flex Data text packet (MT 0xD, status bank 0x01 or 0x02) of any form. This is a per-packet codec: it doesn't
/// join packets, check that forms come in order, or check UTF-8 (a code point may span packets, so a packet's bytes
/// need not be valid UTF-8 on their own).
///
/// Word 0: `[0xD | group][form:2 address:2 channel:4][status bank][status]`. Words 1...3 hold 12 text bytes, most
/// significant byte of word 1 first (MIDI 2.0 Workbench `byteRangeArr`, bl-midi2-rs `text.rs`, ni-midi2, cmidi2).
///
/// A 0x00 inside the text is data, not a terminator: cmidi2 (`cmidi2.h`, `cmidi2_ump_flex_data_process`) says a lyric
/// "may contain `\0` as Melisma", and bl-midi2-rs (`flex_data/text.rs`, `TextBytesIterator`) and AM_MIDI2.0Lib
/// (`umpProcessor.cpp`) read past interior 0x00 bytes (both drop them; this codec keeps them). ni-midi2's
/// `payload_as_string` stops at the first 0x00 instead. Only trailing 0x00 bytes are padding, the same rule as
/// `UMPStreamText`: a start or continuation packet is always full (the splitter only shortens the last packet, and
/// ni-midi2 asserts it), so its `bytes` are all 12 bytes; a complete or end packet drops its trailing 0x00 bytes.
/// Either way `packet` re-encodes the received words exactly, except that the ignored channel nibble of a
/// group-addressed packet comes back as 0.
struct UMPFlexDataTextPacket: Equatable, Sendable {
    /// Words 1...3.
    static let maximumByteCount = 12

    let group: UMPGroup
    /// Either address is accepted for every text status: bl-midi2-rs gives each text message an
    /// `OptionalChannelProperty`, ni-midi2's tests build bank 0x01 text channel-addressed, and cmidi2 and
    /// AM_MIDI2.0Lib take the address from the caller. As in `UMPFlexDataMessage`, decoding ignores the
    /// channel nibble of a group-addressed packet.
    let address: UMPFlexDataAddress
    let form: UMPFlexDataForm
    let kind: UMPFlexDataTextKind
    /// Exactly 12 bytes for start and continuation; 0...12 bytes not ending in 0x00 for complete and end.
    let bytes: [UInt8]
    private let storedPacket: UMPPacket

    /// Refuses more than 12 bytes (`textTooLong`), then a start or continuation packet with fewer than 12 bytes
    /// (`notFullPacket`), then a complete or end packet whose last byte is 0x00 (`trailingZeroByte`). Either short
    /// form would decode with different bytes, because the decoder can't tell padding from text.
    init(
        group: UMPGroup,
        address: UMPFlexDataAddress,
        form: UMPFlexDataForm,
        kind: UMPFlexDataTextKind,
        bytes: [UInt8]
    ) throws(UMPFlexDataRefusal) {
        guard bytes.count <= Self.maximumByteCount else { throw .textTooLong(byteCount: bytes.count) }
        switch form {
        case .start, .continuation:
            guard bytes.count == Self.maximumByteCount else { throw .notFullPacket(byteCount: bytes.count) }
        case .complete, .end:
            guard bytes.last != 0 else { throw .trailingZeroByte }
        }
        var first = 0xD000_0000 | UInt32(group.value) << 24 | UInt32(form.rawValue) << 22
            | UInt32(kind.bank) << 8 | UInt32(kind.status)
        switch address {
        case .channel(let channel): first |= UInt32(channel.value) << 16
        case .group: first |= 1 << 20
        }
        var data: [UInt32] = [0, 0, 0]
        for (offset, byte) in bytes.enumerated() {
            data[offset / 4] |= UInt32(byte) << (24 - 8 * UInt32(offset % 4))
        }
        do {
            storedPacket = try UMPPacket(words: [first] + data)
        } catch {
            throw .ump(error)
        }
        self.group = group
        self.address = address
        self.form = form
        self.kind = kind
        self.bytes = bytes
    }

    /// The four words; bytes after `bytes` are 0x00, and the channel nibble is 0 when group-addressed.
    var packet: UMPPacket { storedPacket }

    /// Splits one text into packets: one complete packet for 0...12 bytes (an empty text is one complete packet with
    /// no bytes, as bl-midi2-rs writes it; cmidi2 sends no packet), otherwise start, continuation..., end, every packet
    /// but the last full. Bytes are split by count, so a UTF-8 code point may straddle two packets. Interior 0x00 bytes
    /// are kept, even at a packet boundary; a text ending in 0x00 is refused (`trailingZeroByte`), as
    /// `UMPStreamText.packets` does.
    static func packets(
        group: UMPGroup,
        address: UMPFlexDataAddress,
        kind: UMPFlexDataTextKind,
        text: [UInt8]
    ) throws(UMPFlexDataRefusal) -> [UMPFlexDataTextPacket] {
        guard text.last != 0 else { throw .trailingZeroByte }
        guard text.count > maximumByteCount else {
            return [try Self(group: group, address: address, form: .complete, kind: kind, bytes: text)]
        }
        let starts = Array(stride(from: 0, to: text.count, by: maximumByteCount))
        var result: [UMPFlexDataTextPacket] = []
        for (index, offset) in starts.enumerated() {
            let form: UMPFlexDataForm
            if index == 0 {
                form = .start
            } else if index == starts.count - 1 {
                form = .end
            } else {
                form = .continuation
            }
            let chunk = Array(text[offset..<min(offset + maximumByteCount, text.count)])
            result.append(try Self(group: group, address: address, form: form, kind: kind, bytes: chunk))
        }
        return result
    }
}

extension UMPFlexDataTextPacket {
    /// Decodes one text packet of any form. Order of refusals: not MT 0xD, bank or status not a text message
    /// (`unknownStatus`, including every bank 0x00 message), reserved address. The channel nibble of a
    /// group-addressed packet is ignored, and text bytes are never refused.
    init(decoding packet: UMPPacket) throws(UMPFlexDataRefusal) {
        guard packet.messageType == .flexData else { throw .notFlexData(actual: packet.messageType) }
        let words = packet.words
        let first = words[0]
        let bank = UInt8((first >> 8) & 0xFF)
        let status = UInt8(first & 0xFF)
        guard let kind = UMPFlexDataTextKind(bank: bank, status: status) else {
            throw .unknownStatus(bank: bank, status: status)
        }
        let channelBits = UInt8((first >> 16) & 0x0F)
        let address: UMPFlexDataAddress
        switch UInt8((first >> 20) & 0x3) {
        case 0:
            do {
                address = .channel(try UMPChannel(channelBits))
            } catch {
                throw .ump(error)
            }
        case 1:
            // The channel nibble is ignored, as in `UMPFlexDataMessage`; `packet` encodes it as 0.
            address = .group
        case let reserved:
            throw .reservedAddress(status: status, address: reserved)
        }
        let form = UMPFlexDataForm(bits: first >> 22)
        let bytes = Self.textBytes(words, form: form)
        let group: UMPGroup
        do {
            group = try UMPGroup(UInt8((first >> 24) & 0x0F))
        } catch {
            throw .ump(error)
        }
        try self.init(group: group, address: address, form: form, kind: kind, bytes: bytes)
    }

    /// All 12 bytes of words 1...3 for start and continuation; without trailing 0x00 bytes for complete and end.
    private static func textBytes(_ words: [UInt32], form: UMPFlexDataForm) -> [UInt8] {
        var lane: [UInt8] = []
        for word in words[1...3] {
            for shift in [24, 16, 8, 0] as [UInt32] {
                lane.append(UInt8(truncatingIfNeeded: word >> shift))
            }
        }
        guard form == .complete || form == .end else { return lane }
        let length = (lane.lastIndex { $0 != 0 } ?? -1) + 1
        return Array(lane[..<length])
    }
}
