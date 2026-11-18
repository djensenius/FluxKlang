//
//  MIDICIPropertyHeaderScanner.swift
//  FluxKlang
//
//  The bounded JSON scanner behind `MIDICIPropertyHeader.parse(_:)` (#83, slice M83-PXH1, issue #820). It uses only
//  the standard library: no Foundation, `JSONSerialization` or `JSONDecoder`. The grammar is RFC 8259's; the depth
//  limit is this scanner's own engineering bound, not a specification limit.
//

/// One left-to-right pass over Property Exchange header data. It checks the whole JSON document and returns the
/// members of the top-level object in document order. The pass stops at the first failure, so the lowest failing
/// offset wins. It refuses:
/// - `unexpectedEnd` (at the input's count) when the input stops before the document does, empty input included;
/// - `unexpectedByte` for a byte that cannot come next: a top level that is not an object, a missing name, colon or
///   comma, a comma before a closing bracket, or a misspelt `true`, `false` or `null`;
/// - `invalidString` for a byte below 0x20 in a string (at that byte), or for an unknown escape, a `\u` escape that is
///   not four hex digits, or a surrogate without its pair (at the escape's backslash);
/// - `invalidNumber` at the first byte that breaks the number grammar (the `1` of `01`, the `}` of `1.}`);
/// - `tooDeep` at an object or array that would open a level above `maximumDepth`;
/// - `duplicateKey` at the opening quote of a name already used in the same object, at any depth. Names are compared
///   by their decoded code points;
/// - `trailingBytes` at the first byte other than whitespace after the top-level object.
///
/// Bounded: it recurses only into objects and arrays, and refuses any that would go past `maximumDepth` levels. Every
/// loop step consumes at least one byte. The caller has already limited the input to 2,048 bytes below 0x80; a byte
/// of 0x80 or more in a string is `invalidString` here only as a defensive guard. Only `MIDICIPropertyHeader.parse(_:)`
/// calls it, and nothing calls that yet.
struct MIDICIPropertyHeaderScanner {
    /// A member's value, as far as `MIDICIPropertyHeader` types it.
    enum Value {
        case string(String)
        /// The number's bytes as written, which match the JSON number grammar.
        case number(ArraySlice<UInt8>)
        case bool(Bool)
        /// `null`, an object or an array. The contents of an object or an array are checked and then dropped.
        case other
    }

    /// One member of an object: its decoded name, its value and `offset`, the index of the value's first byte.
    struct Member {
        let name: String
        let offset: Int
        let value: Value
    }

    /// The deepest nesting accepted, inclusive; the top-level object is level 1.
    static let maximumDepth = 8
    private static let whitespace: [UInt8] = [0x20, 0x09, 0x0A, 0x0D]
    /// A byte that cannot follow a complete number: a digit, a sign, a point or an exponent letter.
    private static let numberBytes = Array("0123456789+-.eE".utf8)
    /// The escapes other than `\u`, by the letter after the backslash, with the byte each one stands for.
    private static let simpleEscapes: [UInt8: UInt8] = [
        0x22: 0x22, 0x5C: 0x5C, 0x2F: 0x2F, 0x62: 0x08, 0x66: 0x0C, 0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09
    ]

    private let bytes: [UInt8]
    private var index = 0

    /// Checks `bytes` as one JSON object and returns its members in document order. The refusals are in the type's
    /// documentation.
    static func members(of bytes: [UInt8]) throws(MIDICIPropertyHeaderRefusal) -> [Member] {
        var scanner = MIDICIPropertyHeaderScanner(bytes: bytes)
        scanner.skipWhitespace()
        guard try scanner.peek() == UInt8(ascii: "{") else { throw .unexpectedByte(offset: scanner.index) }
        let members = try scanner.scanObject(depth: 1)
        scanner.skipWhitespace()
        guard scanner.index == bytes.count else { throw .trailingBytes(offset: scanner.index) }
        return members
    }

    // MARK: Objects and arrays

    /// Scans the object whose `{` is at `index` and opens level `depth`. Returns its members.
    private mutating func scanObject(depth: Int) throws(MIDICIPropertyHeaderRefusal) -> [Member] {
        try open(depth: depth)
        var members: [Member] = []
        if step(overAnyOf: "}") { return members }
        var names = Set<[UInt8]>()
        repeat {
            skipWhitespace()
            members.append(try scanMember(depth: depth, names: &names))
            skipWhitespace()
        } while try next(closing: UInt8(ascii: "}"))
        return members
    }

    /// Scans the array whose `[` is at `index` and opens level `depth`.
    private mutating func scanArray(depth: Int) throws(MIDICIPropertyHeaderRefusal) {
        try open(depth: depth)
        if step(overAnyOf: "]") { return }
        repeat {
            skipWhitespace()
            _ = try scanValue(depth: depth + 1)
            skipWhitespace()
        } while try next(closing: UInt8(ascii: "]"))
    }

    /// Steps over the `{` or `[` at `index`, and the whitespace after it. Refuses it if it opens a level above
    /// `maximumDepth`.
    private mutating func open(depth: Int) throws(MIDICIPropertyHeaderRefusal) {
        guard depth <= Self.maximumDepth else { throw .tooDeep(offset: index) }
        index += 1
        skipWhitespace()
    }

    /// Runs after a member or an element. Steps over a comma and returns true (another one follows), or steps over
    /// `closing` and returns false.
    private mutating func next(closing: UInt8) throws(MIDICIPropertyHeaderRefusal) -> Bool {
        let byte = try peek()
        guard byte == UInt8(ascii: ",") || byte == closing else { throw .unexpectedByte(offset: index) }
        index += 1
        return byte != closing
    }

    /// Scans one `"name": value` member of an object at level `depth`. Refuses a name already in `names` before
    /// reading its value.
    private mutating func scanMember(
        depth: Int, names: inout Set<[UInt8]>
    ) throws(MIDICIPropertyHeaderRefusal) -> Member {
        let nameOffset = index
        guard try peek() == UInt8(ascii: "\"") else { throw .unexpectedByte(offset: index) }
        let name = try scanString()
        guard names.insert(Array(name.utf8)).inserted else { throw .duplicateKey(name: name, offset: nameOffset) }
        skipWhitespace()
        guard try peek() == UInt8(ascii: ":") else { throw .unexpectedByte(offset: index) }
        index += 1
        skipWhitespace()
        let offset = index
        return try Member(name: name, offset: offset, value: scanValue(depth: depth + 1))
    }

    // MARK: Values

    /// Scans the value at `index`. An object or array there opens level `depth`.
    private mutating func scanValue(depth: Int) throws(MIDICIPropertyHeaderRefusal) -> Value {
        switch try peek() {
        case UInt8(ascii: "{"):
            _ = try scanObject(depth: depth)
            return .other
        case UInt8(ascii: "["):
            try scanArray(depth: depth)
            return .other
        case UInt8(ascii: "\""): return try .string(scanString())
        case UInt8(ascii: "t"): return try scanLiteral("true", .bool(true))
        case UInt8(ascii: "f"): return try scanLiteral("false", .bool(false))
        case UInt8(ascii: "n"): return try scanLiteral("null", .other)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try .number(scanNumber())
        default: throw .unexpectedByte(offset: index)
        }
    }

    /// Steps over `word` one letter at a time and returns `value`.
    private mutating func scanLiteral(_ word: String, _ value: Value) throws(MIDICIPropertyHeaderRefusal) -> Value {
        for letter in word.utf8 {
            guard try peek() == letter else { throw .unexpectedByte(offset: index) }
            index += 1
        }
        return value
    }

    /// Scans `-? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?`. A digit, sign, point or exponent letter straight
    /// after it is refused, so `01`, `1.2.3` and `1e2e3` fail where they go wrong.
    private mutating func scanNumber() throws(MIDICIPropertyHeaderRefusal) -> ArraySlice<UInt8> {
        let start = index
        _ = step(overAnyOf: "-")
        if !step(overAnyOf: "0") { try scanDigits() }
        if step(overAnyOf: ".") { try scanDigits() }
        if step(overAnyOf: "eE") {
            _ = step(overAnyOf: "+-")
            try scanDigits()
        }
        if index < bytes.count, Self.numberBytes.contains(bytes[index]) { throw .invalidNumber(offset: index) }
        return bytes[start..<index]
    }

    /// Steps over one or more digits.
    private mutating func scanDigits() throws(MIDICIPropertyHeaderRefusal) {
        let first = try peek()
        guard Self.isDigit(first) else { throw .invalidNumber(offset: index) }
        while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
    }

    // MARK: Strings

    /// Scans the string whose `"` is at `index` and returns it decoded.
    private mutating func scanString() throws(MIDICIPropertyHeaderRefusal) -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        while true {
            let byte = try peek()
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(scalars)
            case UInt8(ascii: "\\"):
                scalars.append(try scanEscape())
            case 0x20..<0x80:
                scalars.append(Unicode.Scalar(byte))
                index += 1
            default:
                throw .invalidString(offset: index)
            }
        }
    }

    /// Decodes the escape whose backslash is at `index`. An unknown escape, a bad hex digit and a surrogate without
    /// its pair are refused at that backslash.
    private mutating func scanEscape() throws(MIDICIPropertyHeaderRefusal) -> Unicode.Scalar {
        let start = index
        index += 1
        let letter = try peek()
        index += 1
        if let simple = Self.simpleEscapes[letter] { return Unicode.Scalar(simple) }
        guard letter == UInt8(ascii: "u") else { throw .invalidString(offset: start) }
        let unit = try scanHexUnit(escape: start)
        if (0xD800...0xDBFF).contains(unit) { return try scanLowSurrogate(high: unit, escape: start) }
        // A lone low surrogate (0xDC00 to 0xDFFF) is not a scalar.
        guard let scalar = Unicode.Scalar(unit) else { throw .invalidString(offset: start) }
        return scalar
    }

    /// Reads the four hex digits of the `\u` escape whose backslash is at `start`.
    private mutating func scanHexUnit(escape start: Int) throws(MIDICIPropertyHeaderRefusal) -> UInt16 {
        var unit: UInt16 = 0
        for _ in 0..<4 {
            let byte = try peek()
            guard let digit = Self.hexValue(byte) else { throw .invalidString(offset: start) }
            unit = UInt16(digit) | unit << 4
            index += 1
        }
        return unit
    }

    /// Runs after the high surrogate escape whose backslash is at `start`. The next escape must be a `\u` low
    /// surrogate.
    private mutating func scanLowSurrogate(
        high: UInt16, escape start: Int
    ) throws(MIDICIPropertyHeaderRefusal) -> Unicode.Scalar {
        let second = index
        guard try peek() == UInt8(ascii: "\\") else { throw .invalidString(offset: start) }
        index += 1
        guard try peek() == UInt8(ascii: "u") else { throw .invalidString(offset: start) }
        index += 1
        let low = try scanHexUnit(escape: second)
        guard (0xDC00...0xDFFF).contains(low) else { throw .invalidString(offset: start) }
        let value = 0x1_0000 + (UInt32(high - 0xD800) << 10) + UInt32(low - 0xDC00)
        // A defensive guard that cannot fail: the value is always a scalar from 0x10000 to 0x10FFFF.
        guard let scalar = Unicode.Scalar(value) else { throw .invalidString(offset: start) }
        return scalar
    }

    // MARK: Bytes

    /// The byte at `index`. Refuses the end of the input.
    private func peek() throws(MIDICIPropertyHeaderRefusal) -> UInt8 {
        guard index < bytes.count else { throw .unexpectedEnd(offset: index) }
        return bytes[index]
    }

    /// Steps over the next byte if it is one of the ASCII `choices`, and says whether it did.
    private mutating func step(overAnyOf choices: String) -> Bool {
        guard index < bytes.count, choices.utf8.contains(bytes[index]) else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, Self.whitespace.contains(bytes[index]) { index += 1 }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}
