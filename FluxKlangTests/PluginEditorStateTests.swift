import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Opaque plugin state references, restore qualification, the inactive restore plan and the editor
/// fallback (#77, slice PLG4). The tests live in extensions of this suite; this file holds the fixtures.
@Suite(.productionAccessAudit)
struct PluginEditorStateTests {
    static let baseVersion: UInt32 = 0x0002_0100

    static func identity(_ subtype: String = "Verb", format: PluginFormat = .audioUnitV2) throws -> PluginIdentity {
        try PluginIdentity(
            format: format, type: PluginFourCharacterCode("aufx"),
            subtype: PluginFourCharacterCode(subtype), manufacturer: PluginFourCharacterCode("Acme")
        )
    }

    static func tag(_ text: String = "acme.state.v1") throws -> PluginVendorTag {
        try PluginVendorTag(text)
    }

    static func snapshot(
        blob: [UInt8] = [1, 2, 3], storageClass: StateStorageClass = .fullStateForDocument,
        identity: PluginIdentity? = nil, version: UInt32 = baseVersion, vendor: String = "acme.state.v1"
    ) throws -> PluginStateSnapshot {
        try PluginStateSnapshot.capture(
            blob: blob, storageClass: storageClass, identity: identity ?? Self.identity(),
            version: PluginVersion(rawValue: version), vendorTag: tag(vendor)
        )
    }

    static func target(
        identity: PluginIdentity? = nil, version: UInt32 = baseVersion, vendor: String = "acme.state.v1"
    ) throws -> PluginStateTarget {
        try PluginStateTarget(
            identity: identity ?? Self.identity(), version: PluginVersion(rawValue: version), vendorTag: tag(vendor)
        )
    }

    static func range(
        _ lower: UInt32, _ upper: UInt32, identity: PluginIdentity? = nil, vendor: String = "acme.state.v1"
    ) throws -> QualifiedVersionRange {
        try QualifiedVersionRange(
            identity: identity ?? Self.identity(), vendorTag: tag(vendor),
            lower: PluginVersion(rawValue: lower), upper: PluginVersion(rawValue: upper)
        )
    }

    static func evidence(_ ranges: QualifiedVersionRange...) throws -> QualifiedVersionEvidence {
        try QualifiedVersionEvidence(ranges: ranges)
    }

    static func controlID(_ raw: String) throws -> PluginControlID {
        try PluginControlID(raw)
    }

    static func controls(_ raws: [String]) throws -> EditorControlSet {
        try EditorControlSet(ids: raws.map { try controlID($0) })
    }
}
