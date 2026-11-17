import Foundation

/// Why a package could not be inspected. Cases carry nothing: no path, URL, bookmark bytes, OS error
/// text, decoder text or identity. `CaseIterable` keeps it that way, because Swift cannot synthesize it
/// for an enum with associated values.
enum ProjectPackageInspectionRefusal: Error, Equatable, Sendable, CaseIterable {
    case notFound
    case accessDenied
    /// The location is not a directory, including a link to one: the root link is never followed.
    case notAPackage
    /// A link, special file, hard-linked file or mount-point crossing.
    case unsupportedEntry
    case tooManyEntries
    case tooDeep
    case pathTooLong
    /// A member name that is not a safe, NFC, package-relative name.
    case invalidMemberName
    case memberTooLarge
    case packageTooLarge
    case manifestTooLarge
    /// The manifest, or a member the manifest lists, is absent or not a regular file.
    case missingMember
    case declaredLengthMismatch
    case digestMismatch
    case changedWhileReading
    /// Malformed manifest JSON, a wrong contract, or an invalid or missing version.
    case unreadableManifest
    /// A newer manifest version or unsupported required features.
    case unsupportedManifest
    /// Manifest declarations disagree with each other, with the documents or with the package layout.
    case inconsistentManifest
    case undecodableDocument
    case unsupportedDocument
    /// An unversioned or older document; nothing is migrated here.
    case legacyDocument
    /// A document beyond its byte or record bounds.
    case documentTooLarge
    /// The caller's admission policy or chunk size is invalid.
    case invalidPolicy
    /// The task was cancelled; the read still ran to completion and its result was discarded.
    case cancelled
    /// Any other IO failure.
    case readFailed
}

extension ProjectPackageInspectionRefusal {
    /// Classifies by type alone; the error value itself is discarded.
    init(_ error: any Error) {
        switch error {
        case let error as ProjectPackageDocumentError: self.init(error)
        case let error as ProjectPackageError: self.init(error)
        case let error as ProjectPackageIOError: self.init(error)
        case let error as ProjectPackageManifestError: self.init(error)
        case let error as ContractVersionError: self.init(error)
        case is ProjectGraphVersionError: self = .unsupportedManifest
        case is ProjectGraphLimitError: self = .documentTooLarge
        case is DecodingError: self = .unreadableManifest
        default: self = .readFailed
        }
    }

    init(_ error: ProjectPackageDocumentError) {
        switch error {
        case .undecodableProject, .undecodableGraph: self = .undecodableDocument
        // `unencodable*` and `unsupportedExtraRole` come only from assembly, not from reading.
        case .unsupportedProject, .unsupportedGraph, .unencodableProject, .unencodableGraph:
            self = .unsupportedDocument
        case .legacyProject, .legacyGraph: self = .legacyDocument
        case .projectBounds, .graphBounds: self = .documentTooLarge
        case .unsupportedExtraRole: self = .inconsistentManifest
        case let .package(error): self.init(error)
        case let .manifest(error): self.init(error)
        case let .packageIO(error): self.init(error)
        }
    }

    // One branch per reviewed group; exhaustive so a new reader error forces a mapping decision.
    // swiftlint:disable:next cyclomatic_complexity
    init(_ error: ProjectPackageError) {
        switch error {
        case .invalidLimits: self = .invalidPolicy
        case .pathTooLong: self = .pathTooLong
        case .pathTooDeep: self = .tooDeep
        case .invalidPath, .nonNFCPath: self = .invalidMemberName
        case .unsupportedKind: self = .unsupportedEntry
        case .directoryByteCount, .negativeByteCount, .duplicatePath, .missingParent, .parentNotDirectory:
            self = .inconsistentManifest
        case .entryLimitExceeded: self = .tooManyEntries
        case .fileAlreadyOpen, .noOpenFile: self = .readFailed
        case .entryBytesExceeded: self = .memberTooLarge
        case .totalBytesExceeded, .byteCountOverflow: self = .packageTooLarge
        case .declaredBytesExceeded, .declaredByteCountMismatch: self = .declaredLengthMismatch
        }
    }

    init(_ error: ProjectPackageIOError) {
        switch error {
        case .missingMember: self = .missingMember
        case .digestMismatch: self = .digestMismatch
        case .memberChanged: self = .changedWhileReading
        case .hardLinkedMember, .crossedMountPoint: self = .unsupportedEntry
        // Writer-only failures; the reader never throws them.
        case .destinationExists, .destinationParentRefused, .destinationChanged: self = .readFailed
        case let .system(code): self.init(systemCode: code)
        }
    }

    /// Only the code's class survives; the code itself is discarded.
    private init(systemCode code: Int32) {
        switch code {
        case ENOENT: self = .notFound
        case EACCES, EPERM: self = .accessDenied
        case ENOTDIR: self = .notAPackage
        case ELOOP: self = .unsupportedEntry
        default: self = .readFailed
        }
    }

    init(_ error: ProjectPackageManifestError) {
        switch error {
        case .manifestBytesExceeded: self = .manifestTooLarge
        case .duplicateGraph, .duplicateResource, .emptyResource, .invalidContentDigest, .projectMismatch,
             .graphMismatch, .conflictingAssetByteCount:
            self = .inconsistentManifest
        }
    }

    /// Mirrors document classification: only a newer version is unsupported.
    init(_ error: ContractVersionError) {
        switch error {
        case .wrongContract, .invalidVersion: self = .unreadableManifest
        case .unsupportedVersion: self = .unsupportedManifest
        }
    }
}
