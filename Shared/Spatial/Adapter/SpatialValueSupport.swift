//
//  SpatialValueSupport.swift
//  FluxKlang
//
//  Shared identifiers, typed errors and bounded text helpers for the neutral
//  spatial value model (#114).
//

import Foundation

enum SpeakerTag: ContractIDTag {}
enum SpatialSourceTag: ContractIDTag {}
enum SpeakerGroupTag: ContractIDTag {}

typealias SpeakerID = ContractID<SpeakerTag>
typealias SpatialSourceID = ContractID<SpatialSourceTag>
typealias SpeakerGroupID = ContractID<SpeakerGroupTag>

/// Why a spatial value is invalid.
enum SpatialLayoutError: Error, Equatable, Sendable {
    case nonFiniteCoordinate
    /// A strictly validated (decoded) coordinate lies outside `−1…1`.
    case coordinateOutOfRange
    /// The layout envelope names another contract, a newer or an invalid version.
    case version(ContractVersionError)
    /// The layout is an older or unversioned envelope; no migration exists yet.
    case noMigrationPath(ContractVersion)
    case tooManySpeakers(Int)
    case tooManyGroups(Int)
    case tooManySources(Int)
    case duplicateSpeaker(SpeakerID)
    case duplicateGroup(SpeakerGroupID)
    case duplicateSource(SpatialSourceID)
    case emptyGroup(SpeakerGroupID)
    case unknownGroupMember(SpeakerGroupID, SpeakerID)
    case duplicateGroupMember(SpeakerGroupID, SpeakerID)
    case invalidBlur
    case invalidWidth
    case invalidRolloff
    case invalidChannelCount(Int)
    case tooMuchEvidence(Int)
    case evidenceTooLong(Int)
}

/// Opaque legacy evidence (e.g. a console reference) kept for review only. It is
/// never parsed, matched or used to route.
enum SpatialEvidence {
    static let maximumLength = 256

    static func validate(_ evidence: String?) throws(SpatialLayoutError) {
        guard let count = evidence?.utf8.count else { return }
        guard count <= maximumLength else { throw .evidenceTooLong(count) }
    }
}

/// Display names are normalised, never refused: every control character
/// (Unicode `Cc`, including newlines and tabs) becomes a space, the result is cut
/// on a `Character` boundary to at most `maximumLength` UTF-8 bytes, and an
/// empty result becomes `nil`.
enum SpatialName {
    static let maximumLength = 128

    static func normalize(_ name: String?) -> String? {
        guard let name else { return nil }
        var result = ""
        var bytes = 0
        for character in name {
            let clean: Character = character.unicodeScalars.contains {
                $0.properties.generalCategory == .control
            } ? " " : character
            let size = clean.utf8.count
            guard bytes + size <= maximumLength else { break }
            result.append(clean)
            bytes += size
        }
        return result.isEmpty ? nil : result
    }
}

/// Wraps a spatial validation failure as `DecodingError.dataCorrupted`, keeping
/// the typed error as `underlyingError`.
enum SpatialDecoding {
    static func corrupted(_ decoder: any Decoder, _ error: SpatialLayoutError) -> DecodingError {
        .dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Invalid spatial value: \(error)",
            underlyingError: error
        ))
    }
}
