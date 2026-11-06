import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectRecoveryTests {
    private struct RetentionCopy: Equatable {
        let role: SaveCopyRole
        let version: SaveContentVersion
        let label: String
        let releaseAfter: SaveContentVersion?
        let pinned: Bool
    }

    private static func retentionVersion(_ value: String) throws -> SaveContentVersion {
        try SaveContentVersion.make(digest: value)
    }

    private static func retentionCopies(_ session: SaveSession) -> [RetentionCopy] {
        session.retainedCopies.map {
            RetentionCopy(
                role: $0.role,
                version: $0.version,
                label: $0.label,
                releaseAfter: $0.releaseAfter,
                pinned: $0.pinned
            )
        }
    }

    @Test func keepRemoteReleasesEveryUnpinnedCopy() throws {
        let base = try Self.retentionVersion("all-base")
        let firstLocal = try Self.retentionVersion("all-local-one")
        let local = try Self.retentionVersion("all-local-two")
        let firstRemote = try Self.retentionVersion("all-remote-one")
        let remote = try Self.retentionVersion("all-remote-two")
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: firstLocal))
        _ = try session.reduce(.edit(local: local))
        _ = try session.reduce(.externalChange(remote: firstRemote))
        _ = try session.reduce(.externalChange(remote: remote))

        #expect(try session.reduce(.conflictResolved(choice: .keepRemote)) == [
            .conflictResolutionApplied(choice: .keepRemote, requiresReview: true),
            .releaseCopy(
                role: .local, version: firstLocal, label: "edited-local-all-local-one"
            ),
            .releaseCopy(
                role: .local, version: local, label: "conflict-local-all-local-two"
            ),
            .releaseCopy(
                role: .remote, version: firstRemote, label: "conflict-remote-all-remote-one"
            ),
            .releaseCopy(
                role: .remote, version: remote, label: "conflict-remote-all-remote-two"
            )
        ])
        #expect(session.state == .clean(version: remote))
        #expect(Self.retentionCopies(session).isEmpty)
    }

    @Test func everyUnpinnedCopyGetsReleasedBeforeCleanState() throws {
        let base = try Self.retentionVersion("life-base")
        let firstLocal = try Self.retentionVersion("life-local-one")
        let secondLocal = try Self.retentionVersion("life-local-two")
        let finalLocal = try Self.retentionVersion("life-local-three")
        let firstRemote = try Self.retentionVersion("life-remote-one")
        let secondRemote = try Self.retentionVersion("life-remote-two")
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: firstLocal))
        _ = try session.reduce(.edit(local: secondLocal))
        _ = try session.reduce(.externalChange(remote: firstRemote))
        _ = try session.reduce(.externalChange(remote: secondRemote))
        _ = try session.reduce(.conflictResolved(choice: .keepLocal))
        _ = try session.reduce(.edit(local: finalLocal))
        #expect(session.retainedCopies.allSatisfy {
            $0.pinned || $0.releaseAfter == finalLocal
        })

        let begin = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let attempt) = begin.first else {
            Issue.record("Expected save of final local version")
            return
        }
        #expect(try session.reduce(.saveCompleted(attempt: attempt, version: finalLocal)) == [
            .releaseCopy(
                role: .local, version: firstLocal, label: "edited-local-life-local-one"
            ),
            .releaseCopy(
                role: .local, version: secondLocal, label: "conflict-local-life-local-two"
            ),
            .releaseCopy(
                role: .remote, version: firstRemote, label: "conflict-remote-life-remote-one"
            ),
            .releaseCopy(
                role: .remote, version: secondRemote, label: "conflict-remote-life-remote-two"
            )
        ])
        #expect(session.state == .clean(version: finalLocal))
        #expect(session.retainedCopies.allSatisfy { $0.pinned })
    }

    @Test func repeatedKeepBothReusesExistingPinnedCopy() throws {
        let base = try Self.retentionVersion("reuse-base")
        let local = try Self.retentionVersion("reuse-local")
        let remote = try Self.retentionVersion("reuse-remote")
        let nextRemote = try Self.retentionVersion("reuse-next")
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))
        #expect(try session.reduce(.externalChange(remote: remote)) == [
            .retainCopy(role: .local, version: local, label: "conflict-local-reuse-local"),
            .retainCopy(role: .remote, version: remote, label: "conflict-remote-reuse-remote"),
            .presentConflict(base: base, local: local, remote: remote)
        ])
        #expect(try session.reduce(.conflictResolved(choice: .keepBoth)) == [
            .retainCopy(
                role: .remote, version: remote, label: "keep-both-remote-reuse-remote"
            ),
            .conflictResolutionApplied(choice: .keepBoth, requiresReview: true),
            .releaseCopy(
                role: .remote, version: remote, label: "conflict-remote-reuse-remote"
            )
        ])
        #expect(try session.reduce(.externalChange(remote: nextRemote)) == [
            .retainCopy(
                role: .remote, version: nextRemote, label: "conflict-remote-reuse-next"
            ),
            .presentConflict(base: remote, local: local, remote: nextRemote)
        ])
        #expect(try session.reduce(.externalChange(remote: remote)) == [
            .retainCopy(role: .remote, version: remote, label: "conflict-remote-reuse-remote"),
            .presentConflict(base: remote, local: local, remote: remote)
        ])

        #expect(try session.reduce(.conflictResolved(choice: .keepBoth)) == [
            .conflictResolutionApplied(choice: .keepBoth, requiresReview: true),
            .releaseCopy(
                role: .remote, version: remote, label: "conflict-remote-reuse-remote"
            )
        ])
        #expect(session.state == .dirty(base: remote, local: local))
        #expect(Self.retentionCopies(session) == [
            RetentionCopy(
                role: .local,
                version: local,
                label: "conflict-local-reuse-local",
                releaseAfter: local,
                pinned: false
            ),
            RetentionCopy(
                role: .remote,
                version: remote,
                label: "keep-both-remote-reuse-remote",
                releaseAfter: nil,
                pinned: true
            ),
            RetentionCopy(
                role: .remote,
                version: nextRemote,
                label: "conflict-remote-reuse-next",
                releaseAfter: local,
                pinned: false
            )
        ])
    }
}
