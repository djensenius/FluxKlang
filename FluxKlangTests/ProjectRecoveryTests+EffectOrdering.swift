import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectRecoveryTests {
    @Test func copyEffectsSortByRoleVersionAndUTF8LabelAndDeduplicateFullKeys() throws {
        let versionA = try SaveContentVersion.make(digest: "a")
        let versionB = try SaveContentVersion.make(digest: "b")
        let versionZ = try SaveContentVersion.make(digest: "z")
        let effects: [SaveEffect] = [
            .retainCopy(role: .remote, version: versionA, label: "remote"),
            .retainCopy(role: .local, version: versionZ, label: "last"),
            .retainCopy(role: .local, version: versionA, label: "zeta"),
            .retainCopy(role: .local, version: versionA, label: "alpha"),
            .retainCopy(role: .local, version: versionA, label: "alpha"),
            .presentConflict(base: versionA, local: versionB, remote: versionZ),
            .releaseCopy(role: .remote, version: versionA, label: "remote"),
            .releaseCopy(role: .local, version: versionZ, label: "z-release"),
            .releaseCopy(role: .local, version: versionA, label: "a-release"),
            .releaseCopy(role: .local, version: versionA, label: "a-release")
        ]

        #expect(SaveEffect.ordered(effects) == [
            .retainCopy(role: .local, version: versionA, label: "alpha"),
            .retainCopy(role: .local, version: versionA, label: "zeta"),
            .retainCopy(role: .local, version: versionZ, label: "last"),
            .retainCopy(role: .remote, version: versionA, label: "remote"),
            .presentConflict(base: versionA, local: versionB, remote: versionZ),
            .releaseCopy(role: .local, version: versionA, label: "a-release"),
            .releaseCopy(role: .local, version: versionZ, label: "z-release"),
            .releaseCopy(role: .remote, version: versionA, label: "remote")
        ])
    }

    @Test func effectOrderingDoesNotRegroupAcrossStateEffects() throws {
        let version = try SaveContentVersion.make(digest: "interleaved")
        let effects: [SaveEffect] = [
            .releaseCopy(role: .remote, version: version, label: "remote-release"),
            .presentConflict(base: version, local: version, remote: version),
            .retainCopy(role: .local, version: version, label: "local-retain")
        ]
        #expect(SaveEffect.ordered(effects) == effects)
    }

    @Test func normalizationVariantLabelsRemainByteExact() throws {
        let version = try SaveContentVersion.make(digest: "label-version")
        let composed = SaveCopyLabel("\u{00E9}")
        let decomposed = SaveCopyLabel("e\u{0301}")
        #expect(decomposed < composed)
        let composedRetain = SaveEffect.retainCopy(
            role: .local, version: version, label: composed
        )
        let decomposedRetain = SaveEffect.retainCopy(
            role: .local, version: version, label: decomposed
        )
        #expect(composedRetain != decomposedRetain)
        #expect(SaveEffect.ordered([composedRetain, decomposedRetain]) == [
            decomposedRetain, composedRetain
        ])
        #expect(SaveEffect.ordered([composedRetain, decomposedRetain]).count == 2)

        let composedRelease = SaveEffect.releaseCopy(
            role: .local, version: version, label: composed
        )
        let decomposedRelease = SaveEffect.releaseCopy(
            role: .local, version: version, label: decomposed
        )
        #expect(composedRelease != decomposedRelease)
        #expect(SaveEffect.ordered([composedRelease, decomposedRelease]) == [
            decomposedRelease, composedRelease
        ])
        #expect(SaveEffect.ordered([composedRelease, decomposedRelease]).count == 2)

        let base = try SaveContentVersion.make(digest: "label-base")
        let composedVersion = try SaveContentVersion.make(digest: composed.stringValue)
        let changedVersion = try SaveContentVersion.make(digest: "label-final")
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: composedVersion))
        _ = try session.reduce(.edit(local: changedVersion))
        let copy = try #require(session.retainedCopies.first)
        let expected = SaveConflictLabels.make("edited", role: .local, version: composedVersion)
        let normalizedVariant = SaveCopyLabel("edited-local-e\u{0301}")
        #expect(copy.label == expected)
        #expect(copy.hasIdentity(role: .local, version: composedVersion, label: expected))
        #expect(!copy.hasIdentity(
            role: .local, version: composedVersion, label: normalizedVariant
        ))
    }
}
