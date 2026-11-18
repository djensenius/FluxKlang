//
//  MIDICIPropertyHeader.swift
//  FluxKlang
//
//  The header data of a MIDI-CI Property Exchange message as a typed value (#83, slice M83-PXH1, issue #820): a
//  pure, bounded parse of the header JSON that uses only the standard library. Only `MIDICIPropertyContent.decode(_:)`
//  calls it, and nothing calls that yet.
//
//  Provenance: the Property Exchange specifications (M2-102-UM, the Common Rules, and M2-103-UM, the resources) were
//  not read. `resource`, `status` and `command` appear in the repo's header goldens
//  (`MIDICIMessageTests+PropertyData.swift`). The other names (`resId`, `message`, `subscribeId`, `mediaType`,
//  `offset`, `limit`, `totalCount`, `setPartial`, `cacheTime` and `mutualEncoding`) and every type come from the
//  slice brief and were not checked against the specification. The bounds (2,048 bytes, 8 levels, 0 to
//  2,147,483,647) are this parser's own engineering choices.
//

/// The encoding of a Property Exchange body, named by the header's `mutualEncoding`. `ASCII`, `Mcoded7` and
/// `zlib+Mcoded7` are matched byte for byte, so another case or a canonically equivalent spelling is another name.
/// Any other name is kept as `other` (lenient receive). Only `MIDICIPropertyHeader.parse(_:)` makes one, and only
/// `MIDICIPropertyContent.decode(_:)` calls that; nothing calls that yet.
enum MIDICIPropertyEncoding: Equatable, Hashable, Sendable {
    case ascii
    case mcoded7
    case zlibMcoded7
    case other(String)

    private static let names: [(name: String, encoding: MIDICIPropertyEncoding)] = [
        ("ASCII", .ascii), ("Mcoded7", .mcoded7), ("zlib+Mcoded7", .zlibMcoded7)
    ]

    init(name: String) {
        self = Self.names.first { MIDICIPropertyHeader.isSpelled(name, as: $0.name) }?.encoding ?? .other(name)
    }
}

/// The header data of one Property Exchange message, as `parse(_:)` reads it. The header data is the JSON object
/// that `MIDICIPropertyChunk.headerData` carries as opaque bytes. Each field is named after its JSON key and is nil
/// when that key is absent. The exception is `encoding` (`mutualEncoding`), which is `.ascii` when its key is absent.
/// `unknownKeys` holds the names of every other top-level member, sorted by their UTF-8 bytes; their values are
/// checked as JSON and then dropped. Rules that depend on the message kind (a resource in an inquiry, a status in a
/// reply) are not checked. Only `MIDICIPropertyContent.decode(_:)` calls `parse(_:)`, and nothing calls that yet.
struct MIDICIPropertyHeader: Equatable, Hashable, Sendable {
    var resource: String?
    /// `resId`.
    var resID: String?
    var status: Int?
    var message: String?
    /// Kept as written; the commands are not checked.
    var command: String?
    /// `subscribeId`.
    var subscribeID: String?
    /// No default media type is applied.
    var mediaType: String?
    var offset: Int?
    var limit: Int?
    var totalCount: Int?
    var setPartial: Bool?
    var cacheTime: Int?
    /// `mutualEncoding`, or `.ascii` when it is absent.
    var encoding: MIDICIPropertyEncoding = .ascii
    var unknownKeys: [String] = []

    /// The known keys with a string value, by JSON name.
    private enum StringKey: String, CaseIterable {
        case resource, resID = "resId", message, command, subscribeID = "subscribeId", mediaType
    }

    /// The known keys with an integer value, by JSON name.
    private enum IntegerKey: String, CaseIterable {
        case status, offset, limit, totalCount, cacheTime
    }

    /// Whether `name` is `spelling` byte for byte. Every key and encoding name is matched this way, as the scanner
    /// compares duplicate names. `==` is not used because it treats canonically equivalent strings as equal (U+212A
    /// KELVIN SIGN and "K", for example).
    static func isSpelled(_ name: String, as spelling: String) -> Bool {
        name.utf8.elementsEqual(spelling.utf8)
    }

    /// Parses header data. It refuses, in this order:
    /// 1. more than `MIDICIPropertyChunk.maximumHeaderBytes` (2,048) bytes, as `tooLong`, before reading any byte;
    /// 2. a byte of 0x80 or more, as `byteHigh` at the first one;
    /// 3. anything but one JSON object (RFC 8259) that is at most 8 levels deep, repeats no name in any object and has
    ///    only whitespace after it. This is one left-to-right pass of `MIDICIPropertyHeaderScanner`, where the first
    ///    failing offset wins;
    /// 4. a known key whose value has the wrong type (`wrongType`) or range (`outOfRange`): the first one in document
    ///    order, at its value's offset.
    ///
    /// `status`, `offset`, `limit`, `totalCount` and `cacheTime` are integers from 0 to 2,147,483,647, written with
    /// digits only. A fraction or an exponent is `wrongType`; a minus sign (`-0` included) or a larger value is
    /// `outOfRange`. `setPartial` is a Boolean, and every other known key is a string. `null` is the wrong type for
    /// every known key.
    static func parse(_ bytes: [UInt8]) throws(MIDICIPropertyHeaderRefusal) -> MIDICIPropertyHeader {
        let maximum = MIDICIPropertyChunk.maximumHeaderBytes
        guard bytes.count <= maximum else { throw .tooLong(count: bytes.count, limit: maximum) }
        if let offset = bytes.firstIndex(where: { $0 >= 0x80 }) { throw .byteHigh(offset: offset) }
        let members = try MIDICIPropertyHeaderScanner.members(of: bytes)
        var header = MIDICIPropertyHeader()
        for member in members {
            try header.assign(member)
        }
        header.unknownKeys.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return header
    }

    /// Types one top-level member into its field, or keeps its name in `unknownKeys`.
    private mutating func assign(_ member: MIDICIPropertyHeaderScanner.Member) throws(MIDICIPropertyHeaderRefusal) {
        if let key = member.key(StringKey.self) {
            try set(key, member.string())
        } else if let key = member.key(IntegerKey.self) {
            try set(key, member.integer())
        } else if Self.isSpelled(member.name, as: "setPartial") {
            setPartial = try member.bool()
        } else if Self.isSpelled(member.name, as: "mutualEncoding") {
            encoding = try MIDICIPropertyEncoding(name: member.string())
        } else {
            unknownKeys.append(member.name)
        }
    }

    private mutating func set(_ key: StringKey, _ value: String) {
        switch key {
        case .resource: resource = value
        case .resID: resID = value
        case .message: message = value
        case .command: command = value
        case .subscribeID: subscribeID = value
        case .mediaType: mediaType = value
        }
    }

    private mutating func set(_ key: IntegerKey, _ value: Int) {
        switch key {
        case .status: status = value
        case .offset: offset = value
        case .limit: limit = value
        case .totalCount: totalCount = value
        case .cacheTime: cacheTime = value
        }
    }
}

/// Types a top-level member's value. Each refusal names the member's key and the offset of its value.
private extension MIDICIPropertyHeaderScanner.Member {
    /// The key of `Key` whose JSON name is this member's name, byte for byte.
    func key<Key: CaseIterable & RawRepresentable>(_: Key.Type) -> Key? where Key.RawValue == String {
        Key.allCases.first { MIDICIPropertyHeader.isSpelled(name, as: $0.rawValue) }
    }

    func string() throws(MIDICIPropertyHeaderRefusal) -> String {
        guard case .string(let text) = value else { throw .wrongType(key: name, offset: offset) }
        return text
    }

    func bool() throws(MIDICIPropertyHeaderRefusal) -> Bool {
        guard case .bool(let flag) = value else { throw .wrongType(key: name, offset: offset) }
        return flag
    }

    /// Accepts digits only, from 0 to 2,147,483,647. The scanner has already checked the JSON number grammar, so a
    /// number with no point and no exponent letter is an integer, with or without a minus sign.
    func integer() throws(MIDICIPropertyHeaderRefusal) -> Int {
        guard case .number(let written) = value, !written.contains(where: { "eE.".utf8.contains($0) }) else {
            throw .wrongType(key: name, offset: offset)
        }
        guard written.first != UInt8(ascii: "-") else { throw .outOfRange(key: name, offset: offset) }
        var result = 0
        for digit in written {
            result = 10 * result + Int(digit) - Int(UInt8(ascii: "0"))
            guard result <= Int(Int32.max) else { throw .outOfRange(key: name, offset: offset) }
        }
        return result
    }
}
