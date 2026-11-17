/// A deterministic 64-bit identity fingerprint of a CoreMIDI endpoint, usable as `MIDIEndpointKey.fingerprint`: FNV-1a
/// (draft-eastlake-fnv, section 2) over `encoding`, so it is the same in every process and on every run, unlike
/// `Hasher`, which is seeded per process. The evidence is the uniqueID, manufacturer, model and driver owner. The
/// display name and the endpoint ref are not identity, so a rename or a new ref after a replug never changes it.
enum CoreMIDIEndpointFingerprint {
    /// The 64-bit FNV offset_basis and FNV_Prime (draft-eastlake-fnv, section 5).
    static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    static let prime: UInt64 = 0x0000_0100_0000_01B3

    static func of(_ record: CoreMIDIEndpointRecord) -> UInt64 {
        fnv1a(encoding(
            uniqueID: record.uniqueID, manufacturer: record.manufacturer, model: record.model,
            driverOwner: record.driverOwner
        ))
    }

    /// The canonical bytes: the uniqueID, manufacturer, model and driver owner, in that order. Each field starts with
    /// a presence byte (0 absent, 1 present), so an absent field differs from an empty one and a value cannot shift
    /// into its neighbour. A present uniqueID follows as the 4 big-endian bytes of its bit pattern; a present string
    /// as its UTF-8 byte count (8 bytes, big-endian) and then those bytes as CoreMIDI reported them, not normalised.
    static func encoding(uniqueID: Int32?, manufacturer: String?, model: String?, driverOwner: String?) -> [UInt8] {
        var bytes: [UInt8] = []
        if let uniqueID {
            bytes.append(1)
            append(UInt64(UInt32(bitPattern: uniqueID)), width: 4, to: &bytes)
        } else {
            bytes.append(0)
        }
        for field in [manufacturer, model, driverOwner] {
            guard let field else {
                bytes.append(0)
                continue
            }
            bytes.append(1)
            append(UInt64(field.utf8.count), width: 8, to: &bytes)
            bytes.append(contentsOf: field.utf8)
        }
        return bytes
    }

    /// FNV-1a 64: for each byte, xor it into the hash, then multiply by `prime` modulo 2^64.
    static func fnv1a(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash = offsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }

    private static func append(_ value: UInt64, width: Int, to bytes: inout [UInt8]) {
        for index in stride(from: width - 1, through: 0, by: -1) {
            bytes.append(UInt8(truncatingIfNeeded: value >> (index * 8)))
        }
    }
}

extension CoreMIDIEndpointRecord {
    /// See `CoreMIDIEndpointFingerprint`.
    var fingerprint: UInt64 { CoreMIDIEndpointFingerprint.of(self) }
}
