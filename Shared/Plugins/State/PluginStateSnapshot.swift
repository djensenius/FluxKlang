//
//  PluginStateSnapshot.swift
//  FluxKlang
//
//  An opaque reference to the state a plugin saved (#77, slice PLG4). The blob is
//  never parsed, diffed or merged: it is bytes plus the identity, version and
//  vendor tag of the plugin that produced it, and a storage class that says what
//  the bytes may be used for. There is no variation or preset diff anywhere in
//  this model; two snapshots are equal only when every field and every byte is.
//  Pure values: nothing here calls an Audio Unit, a file or a clock.
//

/// Resource policy of this slice, not Apple limits.
enum PluginStateLimits {
    /// Largest blob a reference may carry (4 MiB).
    static let maximumBlobBytes = 4_194_304
    static let maximumVendorTagBytes = 64
}

enum PluginStateError: Error, Hashable, Sendable {
    case emptyBlob
    case blobTooLarge(count: Int, limit: Int)
    case invalidVendorTag
}

/// Which Audio Unit state property a blob came from. This is STORAGE SUITABILITY,
/// never delta compatibility: it says where the bytes may be kept, not how two
/// blobs relate.
enum StateStorageClass: String, Hashable, Sendable, CaseIterable {
    case fullState
    case fullStateForDocument

    /// `fullStateForDocument` suits a document and a preset recall. `fullState`
    /// may hold session-only data that must not be persisted, so it suits a
    /// preset recall (in-session) only.
    func suits(_ purpose: StatePurpose) -> Bool {
        switch (self, purpose) {
        case (.fullStateForDocument, .document), (.fullStateForDocument, .presetRecall), (.fullState, .presetRecall):
            true
        case (.fullState, .document):
            false
        }
    }
}

enum StatePurpose: String, Hashable, Sendable, CaseIterable {
    case document
    case presetRecall
}

/// The plugin vendor's own tag for its state format. Opaque: it is only compared,
/// by UTF-8 bytes, never by Character or canonical equivalence, so a combining
/// mark never merges two tags. 1...64 bytes, not blank, no control (Cc) or format
/// (Cf) scalars.
struct PluginVendorTag: Hashable, Sendable, CustomStringConvertible {
    let text: String
    private let utf8Bytes: [UInt8]

    init(_ text: String) throws(PluginStateError) {
        let bytes = Array(text.utf8)
        let scalars = text.unicodeScalars
        guard (1...PluginStateLimits.maximumVendorTagBytes).contains(bytes.count),
              !scalars.allSatisfy({ $0.properties.isWhitespace }),
              !scalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) })
        else { throw .invalidVendorTag }
        self.text = text
        utf8Bytes = bytes
    }

    var description: String { text }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.utf8Bytes == rhs.utf8Bytes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(utf8Bytes)
    }
}

/// A local FNV-1a 64-bit digest of a blob: an integrity and identity aid only. It
/// is NOT a security primitive and must not be used to authenticate anything.
struct StateDigest: Hashable, Sendable, CustomStringConvertible {
    let value: UInt64

    private init(value: UInt64) {
        self.value = value
    }

    static func of(_ bytes: [UInt8]) -> StateDigest {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return StateDigest(value: hash)
    }

    /// Sixteen lowercase hex digits.
    var hexString: String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    var description: String { hexString }
}

/// An opaque state blob with the plugin it came from. Built only by `capture`;
/// the digest is computed there and cannot be supplied.
struct PluginStateSnapshot: Hashable, Sendable {
    let blob: [UInt8]
    let storageClass: StateStorageClass
    let identity: PluginIdentity
    let version: PluginVersion
    let vendorTag: PluginVendorTag
    let digest: StateDigest

    var byteCount: Int { blob.count }

    private init(
        blob: [UInt8], storageClass: StateStorageClass, identity: PluginIdentity,
        version: PluginVersion, vendorTag: PluginVendorTag
    ) {
        self.blob = blob
        self.storageClass = storageClass
        self.identity = identity
        self.version = version
        self.vendorTag = vendorTag
        digest = StateDigest.of(blob)
    }

    /// Refuses an empty blob and a blob over `PluginStateLimits.maximumBlobBytes`.
    static func capture(
        blob: [UInt8], storageClass: StateStorageClass, identity: PluginIdentity,
        version: PluginVersion, vendorTag: PluginVendorTag
    ) throws(PluginStateError) -> PluginStateSnapshot {
        guard !blob.isEmpty else { throw .emptyBlob }
        guard blob.count <= PluginStateLimits.maximumBlobBytes else {
            throw .blobTooLarge(count: blob.count, limit: PluginStateLimits.maximumBlobBytes)
        }
        return PluginStateSnapshot(
            blob: blob, storageClass: storageClass, identity: identity, version: version, vendorTag: vendorTag
        )
    }
}
