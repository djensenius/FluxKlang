//
//  ContractCoding.swift
//  FluxKlang
//
//  The JSON coders for contract documents. Documents follow I-JSON (RFC 7493):
//  UTF-8 without a byte order mark, and member names unique by Swift `String`
//  equality (Unicode canonical equivalence); `JSONDecoder` alone silently keeps
//  one duplicate.
//

import Foundation

/// Output is canonical: sorted keys and unescaped slashes. Contract coders must
/// keep the default key, date and data strategies; a key strategy such as
/// `.convertFromSnakeCase` would rename the stray keys `ExtensionFields` keeps.
enum ContractCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Decodes a contract document. Throws `DecodingError.dataCorrupted` first if
    /// the data is not BOM-less UTF-8 (a leading EF BB BF, FE FF or FF FE, or any
    /// NUL byte, which UTF-16/32 JSON always contains; nothing is transcoded), then
    /// if any object at any depth has duplicate member names. Malformed JSON is
    /// left for `JSONDecoder` to report.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let byteOrderMarks: [[UInt8]] = [[0xEF, 0xBB, 0xBF], [0xFE, 0xFF], [0xFF, 0xFE]]
        if byteOrderMarks.contains(where: { data.starts(with: $0) }) || data.contains(0) {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Contract documents must be UTF-8 without a byte order mark"
            ))
        }
        var scanner = DuplicateNameScanner(bytes: [UInt8](data))
        do {
            try scanner.scanValue(depth: 0)
        } catch .duplicate(let name, let path) {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Duplicate member name \"\(name)\" at \(path)"
            ))
        } catch .malformed {}  // Fall through: JSONDecoder reports the precise error.
        return try makeDecoder().decode(type, from: data)
    }
}

/// A single-pass structural walk over JSON bytes that tracks member names per
/// object. Every step consumes input or stops, and nesting is bounded, so it
/// cannot crash or loop on malformed input.
private struct DuplicateNameScanner {
    enum Failure: Error {
        case malformed
        case duplicate(String, path: String)
    }

    private static let maximumDepth = 512
    private static let simpleEscapes: [UInt8: UInt8] = [0x62: 0x08, 0x66: 0x0C, 0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09]
    let bytes: [UInt8]
    var index = 0
    var path: [String] = []

    mutating func scanValue(depth: Int) throws(Failure) {
        guard depth < Self.maximumDepth else { throw .malformed }
        skipWhitespace()
        guard index < bytes.count else { throw .malformed }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            try scanObject(depth: depth)
        case UInt8(ascii: "["):
            try scanArray(depth: depth)
        case UInt8(ascii: "\""):
            _ = try scanString(decoding: false)
        default:
            let start = index
            while index < bytes.count, !Self.isDelimiter(bytes[index]) { index += 1 }
            guard index > start else { throw .malformed }
        }
    }

    private mutating func scanObject(depth: Int) throws(Failure) {
        index += 1
        var names = Set<String>()
        if try consume(UInt8(ascii: "}")) { return }
        repeat {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw .malformed }
            let name = try scanString(decoding: true)
            guard names.insert(name).inserted else {
                throw .duplicate(name, path: "$" + path.joined())
            }
            guard try consume(UInt8(ascii: ":")) else { throw .malformed }
            path.append("." + name)
            try scanValue(depth: depth + 1)
            path.removeLast()
        } while try consume(UInt8(ascii: ","))
        guard try consume(UInt8(ascii: "}")) else { throw .malformed }
    }

    private mutating func scanArray(depth: Int) throws(Failure) {
        index += 1
        if try consume(UInt8(ascii: "]")) { return }
        var element = 0
        repeat {
            path.append("[\(element)]")
            try scanValue(depth: depth + 1)
            path.removeLast()
            element += 1
        } while try consume(UInt8(ascii: ","))
        guard try consume(UInt8(ascii: "]")) else { throw .malformed }
    }

    /// Scans a string starting at its opening quote; returns its decoded value
    /// when `decoding`, otherwise an empty string.
    private mutating func scanString(decoding: Bool) throws(Failure) -> String {
        index += 1
        var utf8: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard let text = decoding ? String(validating: utf8, as: UTF8.self) : "" else { throw .malformed }
                return text
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw .malformed }
                let escape = bytes[index]
                index += 1
                guard decoding else { continue }
                if escape == UInt8(ascii: "u") {
                    utf8.append(contentsOf: String(try scanUnicodeEscape()).utf8)
                } else {
                    utf8.append(Self.simpleEscapes[escape] ?? escape)  // \" \\ \/ map to themselves
                }
            default:
                if decoding { utf8.append(byte) }
            }
        }
        throw .malformed
    }

    /// Decodes the `XXXX` after `\u`, joining a following low surrogate.
    private mutating func scanUnicodeEscape() throws(Failure) -> Character {
        let high = try scanHex4()
        guard (0xD800...0xDBFF).contains(high) else {
            guard let scalar = Unicode.Scalar(high) else { throw .malformed }
            return Character(scalar)
        }
        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
              bytes[index + 1] == UInt8(ascii: "u") else { throw .malformed }
        index += 2
        let low = try scanHex4()
        guard (0xDC00...0xDFFF).contains(low),
              let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
        else { throw .malformed }
        return Character(scalar)
    }

    private mutating func scanHex4() throws(Failure) -> UInt32 {
        guard index + 4 <= bytes.count else { throw .malformed }
        var value: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            guard let digit = Character(Unicode.Scalar(byte)).hexDigitValue else { throw .malformed }
            value = value << 4 | UInt32(digit)
        }
        index += 4
        return value
    }

    /// Skips whitespace, then consumes `byte` if it is next.
    private mutating func consume(_ byte: UInt8) throws(Failure) -> Bool {
        skipWhitespace()
        guard index < bytes.count else { throw .malformed }
        guard bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || ",]}:".utf8.contains(byte)
    }
}
