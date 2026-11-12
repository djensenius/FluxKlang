/// Sub-id 2 of the messages handled by `MIDICIProfileDetailsMessage` (Tables 22, 23 and 28).
enum MIDICIProfileDetailsKind: UInt8, Sendable {
    case detailsInquiry = 0x28
    case detailsReply = 0x29
    case specificData = 0x2F

    /// M2-101-UM v1.2, section 3.3.3, allows the Broadcast MUID for Profile Specific Data only "if defined as allowed
    /// by the active Profile", which a codec cannot see: it accepts either. The Profile Details Inquiry and Reply are
    /// not on the list, so they are addressed to one MUID.
    var destinationRule: MIDICIDestinationRule {
        switch self {
        case .detailsInquiry, .detailsReply: return .oneMUID
        case .specificData: return .either
        }
    }

    /// The one place of the format rule. The Inquiry and its Reply exist from CI 1.2 on (section 7.6 was added in
    /// that revision and Table 23 fixes the format byte at 0x02), so CI 1.1 is refused for them. Table 28 leaves the
    /// format byte open and the layout is the same in both formats, so Profile Specific Data accepts both.
    func accepts(_ format: MIDICIFormat) -> Bool {
        switch self {
        case .detailsInquiry, .detailsReply: return format == .ci12
        case .specificData: return true
        }
    }

    /// Bytes up to and including the last fixed field: the whole message for the Inquiry, up to the length field for
    /// the Reply and for Profile Specific Data.
    var fixedBytes: Int {
        switch self {
        case .detailsInquiry: return MIDICIProfileDetailsMessage.inquiryBytes
        case .detailsReply: return MIDICIProfileDetailsMessage.replyFixedBytes
        case .specificData: return MIDICIProfileDetailsMessage.specificDataFixedBytes
        }
    }
}

/// MIDI-CI Profile Details Inquiry (sub-id 2 0x28), Reply to Profile Details Inquiry (0x29) and Profile Specific
/// Data (0x2F), kept apart from the other CI decoders (which still refuse these three sub-ids with `unknownSubID`; so
/// does this one for 0x2A to 0x2E, which Appendix D lists as reserved, and for every other sub-id). The profile
/// management messages 0x20 to 0x27 are `MIDICIProfileMessage`. This type is the codec of one message only: it sends
/// nothing, keeps no state, does not check that a Reply echoes the profile id and the inquiry target of its Inquiry
/// (section 7.7.1) and does not interpret the target or any data.
///
/// Layout of the payload as `MIDI1Event.sysEx` delivers it (F0 and F7 excluded). The common 13-byte header is
/// `7E, device id, 0D, sub-id 2, format, source MUID (4), destination MUID (4)`, MUIDs 7 bits per byte, least
/// significant first. Then:
/// - 0x28 Inquiry (Table 22): the profile id (5 bytes) and the inquiry target (1 byte). 19 bytes.
/// - 0x29 Reply (Table 23): the same, then the inquiry target data length dl (2 bytes, 14 bit, least significant
///   first) and dl bytes of inquiry target data. `21 + dl` bytes.
/// - 0x2F Profile Specific Data (Table 28): the profile id (5 bytes), the length n of the data (4 bytes, 7 bits each,
///   least significant first, so 28 bits) and n bytes of profile specific data. `22 + n` bytes.
/// Every byte after the first is 7-bit data; a length of 0 is valid.
///
/// Format. 0x28 and 0x29 are CI 1.2 messages: format 0x01 is `unsupportedFormat(1)` on decode and on encode (as for
/// the Process Inquiry messages). 0x2F accepts 0x01 and 0x02. Any other format byte is `unsupportedFormat`.
///
/// Addressing. A broadcast source is `sourceIsBroadcast`. Section 3.3.3 does not list 0x28 and 0x29 among the
/// messages that may use the Broadcast MUID, so a broadcast destination is `destinationIsBroadcast` for them, on
/// decode and on encode. It lists Profile Specific Data "if defined as allowed by the active Profile"; this codec
/// cannot see the profile, so it accepts a broadcast destination for 0x2F.
///
/// The 512-byte rule of section 3.3.3 and of the note under Table 28 (a message to the Broadcast MUID "shall not be
/// larger than 512 bytes or shall have a defined chunking mechanism") is not enforced: a profile may define a
/// chunking mechanism that allows more, and this codec cannot see it. Only the caller's `MIDICILimits` bound the size.
///
/// Device id. Tables 22, 23 and 28 allow 0x00 to 0x0F (channels), 0x7E (group) and 0x7F (function block) and mark
/// 0x10 to 0x7D reserved. As `MIDICIProfileMessage` does, decode and encode accept every 7-bit device id and refuse
/// nothing on it.
///
/// Lenient receive, strict send. Decode refuses only what makes the bytes unreadable (the envelope, a length, a MUID,
/// the addressing, a byte of 0x80 or more) and keeps every value as received, including any inquiry target (0x00 to
/// 0x3F registered, 0x40 to 0x7F profile specific, section 7.6.1) and any data. The Common Rules for MIDI-CI Profiles
/// (M2-102) were not available, so the target and every data field are opaque. Encode refuses a target or a data byte
/// of 0x80 or more.
///
/// Provenance: the layout follows M2-101-UM v1.2 (11 May 2023), sections 7.6, 7.7 and 7.12, Tables 22, 23 and 28, and
/// section 3.3.3. No other project was consulted and no byte array was copied from any source.
enum MIDICIProfileDetailsMessage: Equatable, Hashable, Sendable {
    case detailsInquiry(MIDICIHeader, profile: MIDICapabilityProfileID, target: UInt8)
    case detailsReply(MIDICIHeader, profile: MIDICapabilityProfileID, target: UInt8, data: [UInt8])
    case specificData(MIDICIHeader, profile: MIDICapabilityProfileID, data: [UInt8])

    /// The exact length of the Inquiry and the bytes before the data of the other two (the header, the profile id,
    /// the target and the 2-byte length of the Reply; the header, the profile id and the 4-byte length of 0x2F).
    static let inquiryBytes = MIDICILayout.headerBytes + MIDICapabilityProfileID.byteCount + 1
    static let replyFixedBytes = inquiryBytes + 2
    static let specificDataFixedBytes = MIDICILayout.headerBytes + MIDICapabilityProfileID.byteCount + 4
    /// The Reply's data length is 14 bit.
    static let maximumReplyDataBytes = 0x3FFF

    var header: MIDICIHeader {
        switch self {
        case let .detailsInquiry(header, _, _), let .detailsReply(header, _, _, _), let .specificData(header, _, _):
            return header
        }
    }

    var kind: MIDICIProfileDetailsKind {
        switch self {
        case .detailsInquiry: return .detailsInquiry
        case .detailsReply: return .detailsReply
        case .specificData: return .specificData
        }
    }
}
