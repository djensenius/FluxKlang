import Foundation

/// Declared width of one controller value. Fourteen-bit is a declared width for
/// a single raw value only; pairing two seven-bit messages is not decoded here.
enum EncoderBitWidth: Int, Codable, Hashable, Sendable, CaseIterable {
    case seven = 7
    case fourteen = 14

    var valueCount: Int { 1 << rawValue }
    var maximumRaw: Int { valueCount - 1 }
    var signBit: Int { 1 << (rawValue - 1) }
}

/// A decoded controller input: an absolute normalized position or a signed relative delta.
enum ControlInput: Hashable, Sendable {
    case absolute(normalized: Double)
    case relative(delta: Int)
}

enum EncoderDecodeError: Error, Hashable, Sendable {
    case invalidResolution(Int)
    case rawOutOfRange(Int, lower: Int, upper: Int)
}

/// How a raw controller value is read. Each relative profile has its own zero and
/// sign convention; there is deliberately no shared center-at-64 decoder. Profiles have no
/// polarity parameter: an inverted variant would be a new additive case (e.g.
/// `signMagnitudeInverted`), never a change to an existing case.
enum EncoderProfile: Codable, Hashable, Sendable {
    /// Absolute position with `resolution` distinct raw values, `0..<resolution`.
    case absolute(resolution: Int)
    /// Zero at the half-scale value (64 at seven bits); below it is negative.
    case binaryOffset(width: EncoderBitWidth)
    /// Two's complement: 1 is +1 and the all-ones value (127 at seven bits) is -1.
    case twosComplement(width: EncoderBitWidth)
    /// Top bit is the sign (set means negative), the remaining bits the magnitude.
    case signMagnitude(width: EncoderBitWidth)

    static let maximumResolution = EncoderBitWidth.fourteen.valueCount

    var isRelative: Bool {
        if case .absolute = self { return false }
        return true
    }

    func validate() throws(EncoderDecodeError) {
        if case .absolute(let resolution) = self, !(2...Self.maximumResolution).contains(resolution) {
            throw .invalidResolution(resolution)
        }
    }

    func decode(raw: Int) throws(EncoderDecodeError) -> ControlInput {
        try validate()
        switch self {
        case .absolute(let resolution):
            try Self.require(raw, upper: resolution - 1)
            return .absolute(normalized: Double(raw) / Double(resolution - 1))
        case .binaryOffset(let width):
            try Self.require(raw, upper: width.maximumRaw)
            return .relative(delta: raw - width.signBit)
        case .twosComplement(let width):
            try Self.require(raw, upper: width.maximumRaw)
            return .relative(delta: raw < width.signBit ? raw : raw - width.valueCount)
        case .signMagnitude(let width):
            try Self.require(raw, upper: width.maximumRaw)
            let magnitude = raw & (width.signBit - 1)
            return .relative(delta: raw & width.signBit == 0 ? magnitude : -magnitude)
        }
    }

    private static func require(_ raw: Int, upper: Int) throws(EncoderDecodeError) {
        guard (0...upper).contains(raw) else { throw .rawOutOfRange(raw, lower: 0, upper: upper) }
    }
}
