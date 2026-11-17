import Foundation

/// An immutable, read-only view of one package. `documents` is kept whole: the original manifest and
/// member bytes, unknown fields, extensions, bookmarks, opaque and unlisted members, empty directories,
/// pinned revisions and `requiresReview` stay exactly as read. Diagnostics are derived once and change
/// nothing: no draft is created, no revision advances, and no channel or role is inferred or confirmed.
/// Grants no readiness, bookmark resolution, migration or activation authority.
struct ProjectPackageInspection: Equatable, Sendable {
    /// Validation errors beyond this many are counted, not retained.
    static let maxRetainedValidationErrors = 256

    let documents: ProjectPackageDocuments
    let diagnostics: Diagnostics

    init(documents: ProjectPackageDocuments) {
        self.documents = documents
        diagnostics = Diagnostics(documents)
    }
}

extension ProjectPackageInspection {
    struct Diagnostics: Equatable, Sendable {
        /// Non-strict `ProjectDocument.validationErrors(graphs:)` in its own order, truncated.
        let validationErrors: [ProjectValidationError]
        /// Validation errors found beyond `maxRetainedValidationErrors`.
        let droppedValidationErrorCount: Int
        /// Graphs whose document requires review, in manifest order.
        let reviewRequiredGraphs: [GraphID]
        let memberCounts: MemberCounts
        /// Includes empty and unlisted directories.
        let directoryCount: Int
        /// The manifest plus every member, as read.
        let totalByteCount: Int

        init(_ documents: ProjectPackageDocuments) {
            let errors = documents.project.validationErrors(graphs: documents.graphs)
            let retained = errors.prefix(ProjectPackageInspection.maxRetainedValidationErrors)
            validationErrors = Array(retained)
            droppedValidationErrorCount = errors.count - retained.count
            reviewRequiredGraphs = documents.graphs.filter(\.requiresReview).map(\.id)
            let contents = documents.contents
            memberCounts = MemberCounts(contents.files)
            directoryCount = contents.directories.count
            totalByteCount = contents.files.reduce(contents.manifestBytes.count) { $0 + $1.bytes.count }
        }
    }

    /// Members by manifest role; the manifest itself is not a member.
    struct MemberCounts: Equatable, Sendable {
        private(set) var project = 0
        private(set) var graphs = 0
        private(set) var media = 0
        private(set) var bookmarks = 0
        private(set) var opaqueState = 0
        private(set) var unlisted = 0

        init(_ files: [ProjectPackageFile]) {
            for file in files {
                switch file.role {
                case .project: project += 1
                case .graph: graphs += 1
                case .media: media += 1
                case .bookmark: bookmarks += 1
                case .opaqueState: opaqueState += 1
                case .unlisted: unlisted += 1
                }
            }
        }
    }
}
