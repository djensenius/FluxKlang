//
//  ContractVersion.swift
//  FluxKlang
//
//  The `{contract, version}` envelope every versioned contract carries, and the
//  compatibility policy readers apply to it. Versions are integer majors; within
//  a major version changes are additive and optional only, so a reader of
//  version N accepts any version-N document and preserves unknown optional data.
//

import Foundation

/// Why a document's envelope cannot be read by this build.
enum ContractVersionError: Error, Equatable, Sendable {
    /// The document names a different contract, or names none but has a version.
    case wrongContract(expected: String, found: String?)
    /// The document is a newer major version than this build supports.
    case unsupportedVersion(found: Int, supported: Int)
    /// The version is not a positive integer.
    case invalidVersion(found: Int)
}

/// The `{contract, version}` envelope of a versioned contract document.
struct ContractVersion: Codable, Hashable, Sendable {
    /// The contract name, e.g. `fluxklang.media`.
    let contract: String
    /// The integer major version, starting at 1.
    let version: Int

    /// How a readable document relates to the supported version.
    enum Compatibility: Equatable, Sendable {
        /// The document declares the supported contract and version.
        case current
        /// The document has no version (it predates versioning); read it through
        /// the owner's legacy adapter.
        case legacyUnversioned
        /// The document is an older major version; the owning contract must
        /// migrate it from `from` to the supported version before reading.
        case needsMigration(from: Int)
    }

    /// Applies the policy to a decoded envelope. A missing `version` is legacy
    /// (the contract name may be missing or must match); otherwise the contract
    /// must match; a version above `supported.version` is unsupported and one
    /// below it needs migration.
    static func check(
        contract: String?,
        version: Int?,
        supported: ContractVersion
    ) throws(ContractVersionError) -> Compatibility {
        if let contract, contract != supported.contract {
            throw .wrongContract(expected: supported.contract, found: contract)
        }
        guard let version else { return .legacyUnversioned }
        guard contract != nil else {
            throw .wrongContract(expected: supported.contract, found: nil)
        }
        guard version >= 1 else { throw .invalidVersion(found: version) }
        if version > supported.version {
            throw .unsupportedVersion(found: version, supported: supported.version)
        }
        if version < supported.version {
            return .needsMigration(from: version)
        }
        return .current
    }

    /// Checks this envelope against `supported`.
    func check(supported: ContractVersion) throws(ContractVersionError) -> Compatibility {
        try Self.check(contract: contract, version: version, supported: supported)
    }
}
