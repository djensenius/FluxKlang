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
}
