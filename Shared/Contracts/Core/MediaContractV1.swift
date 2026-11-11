//
//  MediaContractV1.swift
//  FluxKlang
//
//  Rules every media contract v1 record builder shares: the schema's `$defs.id` pattern and this
//  exporter's note rule. Pure and free of media types, so contract and media code can both use them.
//

/// The media contract v1 `$defs.id` pattern, `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`, matched byte by byte.
/// Stricter than `ContractID`, which also admits upper case, `_` and `:`.
enum MediaContractV1ID {
    static func matches(_ raw: String) -> Bool {
        let bytes = Array(raw.utf8)
        guard let first = bytes.first, isLower(first),
              let dot = bytes.firstIndex(of: UInt8(ascii: ".")), dot + 1 < bytes.count else { return false }
        let head = bytes[1..<dot].allSatisfy { isLower($0) || isDigit($0) || $0 == UInt8(ascii: "-") }
        let tail = bytes[(dot + 1)...].allSatisfy {
            isLower($0) || isDigit($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".")
        }
        return head && tail
    }

    private static func isLower(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

/// The TKX1 note rule of the media contract v1 record builders. The schema's `$defs.note` needs only a
/// non-empty string; the byte bound is this exporter's. It also bounds a take's latency evidence
/// (`MeasuredLatency.maximumEvidenceBytes`), which a `takeRecord` writes verbatim.
enum MediaContractV1Note {
    /// The most UTF-8 bytes a note may hold.
    static let maximumBytes = 256

    /// True when `note` holds something other than whitespace and at most `maximumBytes` UTF-8 bytes, so an
    /// empty or all-whitespace note is invalid. Text is never trimmed or normalized.
    static func isValid(_ note: String) -> Bool {
        note.utf8.count <= maximumBytes && note.contains(where: { !$0.isWhitespace })
    }
}
