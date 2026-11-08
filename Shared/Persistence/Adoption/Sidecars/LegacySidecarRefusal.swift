/// The two legacy sidecar files a project may carry along. Identity is the case, never a file name.
enum LegacySidecarSource: Sendable, CaseIterable {
    /// `assistant-pending-studio-draft.json`.
    case pendingDraft
    /// `studio-connections.json`.
    case connections
}

/// What an `oversized` refusal measured: one source on its own, or the two sources together.
enum LegacySidecarInput: Sendable, Equatable {
    case draft
    case connections
    case combined
}

/// Why a sidecar plan or its composition was refused. Carries no bytes, paths or Foundation text.
/// `make` refuses in this order: `oversized(.draft)`, `oversized(.connections)`, `oversized(.combined)`,
/// `empty` (draft, then connections), `notUTF8` (draft, then connections), `undecodable` (draft, then
/// connections), `notAnObject` (draft, then connections). Each stage finishes for both sources before the next
/// stage starts.
enum LegacySidecarRefusal: Error, Equatable, Sendable {
    /// A byte count is over the per-entry cap, or the two counts together are over the package total.
    case oversized(LegacySidecarInput)
    /// The sidecar is present but has zero bytes.
    case empty(LegacySidecarSource)
    /// The bytes are not valid UTF-8; nothing is repaired.
    case notUTF8(LegacySidecarSource)
    /// Not one JSON value: invalid JSON, a byte order mark, a NUL byte or duplicate member names.
    case undecodable(LegacySidecarSource)
    /// Valid JSON whose top level is not an object.
    case notAnObject(LegacySidecarSource)
    /// Composition into a package was refused; only `extending` produces this.
    case assembly(ProjectPackageDocumentError)
}
