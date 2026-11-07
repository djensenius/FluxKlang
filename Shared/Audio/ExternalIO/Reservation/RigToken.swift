//
//  RigToken.swift
//  FluxKlang
//
//  Validated opaque identifier text used for every rig reservation identity and baseline component.
//

/// Which caller-supplied value a `RigToken` was being built for; echoed in the refusal.
enum RigTokenField: String, CaseIterable, Sendable {
    case rigKey
    case owner
    case reservationID
    case experimentID
    case approver
    case clockSource
    case ioConfiguration
    case mixerConfiguration
    case signalPath
    case fallbackPath
}

/// Why token text was refused. Offsets and counts are UTF-8 byte positions, never Character positions.
enum RigTokenFault: Hashable, Sendable {
    case empty
    case tooLong(bytes: Int)
    case badFirstByte
    case illegalByte(offset: Int)
}

/// An opaque identifier: UTF-8 length 1...`maximumTokenBytes`, first byte `[a-z0-9]`, later bytes `[a-z0-9._-]`.
///
/// Built only through the throwing initializer. There is no normalization or trimming; every non-ASCII byte is an
/// illegal byte. Equality, hashing and ordering are byte-wise, so canonically equivalent Unicode never merges two
/// tokens (the alphabet is ASCII, which keeps `String` and byte order identical).
struct RigToken: Hashable, Sendable, Comparable, CustomStringConvertible {
    private let text: String

    /// Validates `text` for `field`. Check order, first failure wins: empty, too long, first byte, later bytes.
    init(_ text: String, field: RigTokenField) throws(RigReservationRefusal) {
        if let fault = Self.fault(in: text.utf8) {
            throw .invalidToken(field: field, fault: fault)
        }
        self.text = text
    }

    var description: String { text }

    static func == (lhs: RigToken, rhs: RigToken) -> Bool {
        lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    static func < (lhs: RigToken, rhs: RigToken) -> Bool {
        lhs.text.utf8.lexicographicallyPrecedes(rhs.text.utf8)
    }

    func hash(into hasher: inout Hasher) {
        for byte in text.utf8 {
            hasher.combine(byte)
        }
    }

    private static func fault(in bytes: String.UTF8View) -> RigTokenFault? {
        let count = bytes.count
        if count == 0 { return .empty }
        if count > RigReservationLimits.maximumTokenBytes { return .tooLong(bytes: count) }
        for (offset, byte) in bytes.enumerated() {
            if offset == 0 {
                if !isLowercaseOrDigit(byte) { return .badFirstByte }
            } else if !isLowercaseOrDigit(byte) && !isPunctuation(byte) {
                return .illegalByte(offset: offset)
            }
        }
        return nil
    }

    private static func isLowercaseOrDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isPunctuation(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
    }
}
