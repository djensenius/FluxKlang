/// Which caller-supplied byte sequence an oversized refusal concerns.
enum LegacyAdoptionInput: Sendable, Equatable {
    case graph
    case endpoints
    /// Both sequences together exceed the package's total byte limit.
    case combined
}

/// Why a legacy StudioGraph could not be adopted into a v1 package. Nothing is produced when one is
/// thrown. Cases carry only caller-validated identities and typed errors, never paths, payload bytes
/// or Foundation text.
enum LegacyAdoptionRefusal: Error, Equatable, Sendable {
    /// Over the package entry/total byte limits or the 4 MiB document ceiling; checked before any decoding.
    case oversizedInput(LegacyAdoptionInput)
    /// A top-level `contract` or `version` member: versioned documents are never adopted as legacy.
    case versionedInput
    /// Not BOM-less UTF-8 JSON in the legacy StudioGraph/StudioEndpoint shape.
    case undecodableInput
    case duplicateEndpoint
    case unsupportedLegacyKind
    /// The legacy graph exceeds a node, edge or endpoint ceiling.
    case legacyBounds(ProjectGraphLimitError)
    /// Nodes sharing a role disagree on direction, signal or channel count.
    case conflictingRole(RoleID)
    /// A role node has a port facing the role's own direction (e.g. an input port on a role input).
    case roleShapeMismatch(RoleID)
    /// Package assembly or the verifying re-decode refused.
    case assembly(ProjectPackageDocumentError)
}
