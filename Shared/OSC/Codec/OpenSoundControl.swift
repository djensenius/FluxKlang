//
//  OpenSoundControl.swift
//  FluxKlang
//
//  Namespace for the pure OSC 1.0 codec. Every type is nested here so nothing
//  collides with SwiftOSC's top-level `OSC*` names used by the WING transport.
//

enum OpenSoundControl {}

extension OpenSoundControl {
    /// Caller-chosen bounds applied to every decode, encode and framing step.
    struct Limits: Sendable, Hashable {
        /// Largest packet (and stream frame) in bytes.
        var maximumPacketBytes: Int
        /// Largest argument count of one message.
        var maximumArguments: Int
        /// Deepest bundle nesting; a top-level bundle has depth 1.
        var maximumBundleDepth: Int
        /// Most bundle elements across the whole packet, at any depth. The default
        /// fits a whole console snapshot (48 channels × 6 parameters = 288).
        var maximumBundleElements: Int
        /// Longest string (address or argument) in UTF-8 bytes, excluding the NUL.
        var maximumStringBytes: Int
        /// Largest blob payload in bytes.
        var maximumBlobBytes: Int
        /// Most wildcard constructs in one address pattern: each `*`, `?` and
        /// `[...]` counts one and each `{...}` alternative counts one.
        var maximumPatternComplexity: Int

        init(
            maximumPacketBytes: Int = 65_536,
            maximumArguments: Int = 128,
            maximumBundleDepth: Int = 8,
            maximumBundleElements: Int = 1_024,
            maximumStringBytes: Int = 1_024,
            maximumBlobBytes: Int = 32_768,
            maximumPatternComplexity: Int = 32
        ) {
            self.maximumPacketBytes = maximumPacketBytes
            self.maximumArguments = maximumArguments
            self.maximumBundleDepth = maximumBundleDepth
            self.maximumBundleElements = maximumBundleElements
            self.maximumStringBytes = maximumStringBytes
            self.maximumBlobBytes = maximumBlobBytes
            self.maximumPatternComplexity = maximumPatternComplexity
        }

        static let standard = Limits()
    }

    /// Why an address or address pattern was refused.
    enum AddressRefusal: Sendable, Hashable {
        case missingLeadingSlash
        case emptyPart
        case invalidCharacter(UInt8)
        case wildcardInAddress(UInt8)
        case unbalancedBracket
        case unbalancedBrace
        case emptyGroup
        case invalidRange
        case tooLong(byteCount: Int, limit: Int)
        case tooComplex(complexity: Int, limit: Int)
    }

    /// Every refusal the codec and framers can report. Malformed input never traps.
    enum CodecError: Error, Sendable, Hashable {
        case emptyPacket
        case packetTooLarge(byteCount: Int, limit: Int)
        case packetNotAligned(byteCount: Int)
        case unrecognizedPacket
        case truncated
        case trailingBytes
        case nonZeroPadding
        case invalidAddress(AddressRefusal)
        case missingTypeTags
        case unknownTypeTag(UInt8)
        case tooManyArguments(limit: Int)
        case unterminatedString
        case stringTooLong(limit: Int)
        case stringContainsNul
        case invalidUTF8
        case negativeLength(Int32)
        case blobTooLarge(byteCount: Int, limit: Int)
        case bundleTooDeep(limit: Int)
        case tooManyElements(limit: Int)
        case invalidElementSize(Int32)
        case frameTooLarge(byteCount: Int, limit: Int)
        case emptyFrame
        case invalidSlipEscape(UInt8)
        case framerFailed
    }
}
