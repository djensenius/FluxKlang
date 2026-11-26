import Foundation
import Testing
@testable import FluxKlang

private typealias Owner = OwnerBench

extension HostAuthorityTests {
    /// AU8a (host-authority-sources.md §9): the owner's session, lease and recovery
    /// hooks against its real authority. No WING, network or UI.
    struct OwnerLifecycle {
        @Test func audioPlanAdmissionIsFencedOnlyForTheOwner() async throws {
            let owner = try await Owner.applying()
            let before = await owner.authority.snapshot()
            let permission = try #require(before.live.permission)
            let graph = GraphDocument(
                id: GraphID(validated: "graph.owner"), revision: .initial,
                nodes: [GraphNode(id: NodeID(validated: "node.owner"), kind: .plugin, label: "Owner")]
            )
            let document = AuthorityBench.projectDocument(project: owner.studio, candidate: graph)
            let request = ActivationRequest(
                draft: DraftID(validated: "draft.owner"), graph: graph.id, baseRevision: .initial,
                hostEpoch: owner.hostEpoch, permission: permission,
                digest: ActivationDigest(rawValue: "sha256:activation"), origin: .human
            )
            let ticket = try await Owner.ticket(owner, Owner.windowOne)
            let ticketCount = await owner.authority.outstandingDirectWriteCount()
            let snapshot = await owner.authority.snapshot()
            let result = await owner.authority.begin(request, candidate: graph,
                                                     projectDocument: document, project: owner.studio)
            #expect(AuthorityBench.refusal(result) == .audioPlanAdmissionUnsupported)
            #expect(await owner.authority.snapshot() == snapshot)
            #expect(await owner.authority.outstandingDirectWriteCount() == ticketCount)
            #expect(Owner.refusal(await owner.authority.redeemDirect(ticket)) == nil)

            // The identical request and live state are admissible without the WING policy.
            let ledger = try GenerationLedger(primaryClock: HostAuthorityOwner.primaryClock, musicalClock: nil,
                                              nominalRate: HostAuthorityOwner.nominalRate)
            let generic = try HostAuthority(host: ledger, live: before.live)
            try await generic.open(project: owner.studio, running: RunningGraph(revision: .initial, prepared: nil))
                .get()
            _ = try await generic.acquire(project: owner.studio, window: Owner.windowOne).get()
            try await generic.begin(request, candidate: graph, projectDocument: document, project: owner.studio)
                .get()
            let admitted = await generic.snapshot()
            #expect(admitted.outstanding[owner.studio] != nil)
            #expect(admitted.queue.count == 1)
            if case .prepare = admitted.queue.pending.first {
                // Generic admission really queued a prepare, not another command.
            } else {
                Issue.record("Expected a generic prepare command")
            }
        }

        @Test func permissionIsNilAtLaunch() async throws {
            let owner = try await Owner.applying(granted: false)
            #expect(await owner.permission == nil)
            #expect(await owner.authority.snapshot().live.permission == nil)
            #expect(await owner.authority.snapshot().lease?.windows == [Owner.windowOne])
            let refused = try await Owner.admit(owner, Owner.windowOne)
            #expect(Owner.refusal(refused) == .gate(.refused(.rejected(.permissionDenied))))
            let forged = try #require(HostAuthorityOwner.admission(
                epoch: owner.hostEpoch, permission: PermissionFingerprint(rawValue: "hp1.forged")
            ))
            #expect(forged.intent.permission == forged.admission.permission)
            #expect(Owner.refusal(await Owner.admit(owner, Owner.windowOne, forged)) == .staleLive)
        }

        @Test func connectAcquiresNothing() async throws {
            let owner = try await Owner.owner()
            #expect(await owner.beginApply(window: Owner.windowOne) == .failure(.noSession))
            await owner.connected(session: UUID())
            #expect(await owner.authority.snapshot().lease == nil)
            for window in [Owner.windowOne, Owner.windowTwo] {
                #expect(Owner.refusal(try await Owner.admit(owner, window)) == .windowCannotWrite(.stopped))
            }
            _ = try await owner.beginApply(window: Owner.windowOne).get()
            #expect(Owner.refusal(try await Owner.admit(owner, Owner.windowOne)) == nil)
        }

        @Test func onlyTheRenderingWindowWrites() async throws {
            let owner = try await Owner.applying()
            #expect(await owner.beginApply(window: Owner.windowTwo) == .failure(.otherWindowRenders))
            #expect(await owner.authority.snapshot().lease?.windows == [Owner.windowOne])
            let other = try await Owner.admit(owner, Owner.windowTwo)
            #expect(Owner.refusal(other) == .gate(.unavailable(.heldByOther(owner.studio))))
            let ticket = try await Owner.ticket(owner, Owner.windowOne)
            #expect(Owner.refusal(await owner.authority.redeemDirect(ticket)) == nil)
        }

        @Test func plannedDisconnectThenReconnect() async throws {
            let owner = try await Owner.applying()
            let old = try await Owner.ticket(owner, Owner.windowOne)
            _ = try await owner.disconnected().get()
            #expect(await owner.session == nil)
            #expect(await owner.authority.snapshot().lease == nil)
            #expect(Owner.refusal(await owner.authority.redeemDirect(old)) == .staleLease)
            #expect(await owner.authority.lifecycle(of: owner.studio, window: Owner.windowOne) == .stopped)

            let second = UUID()
            await owner.connected(session: second)
            #expect(await owner.beginApply(window: Owner.windowOne) == .success(second))
            let snapshot = await owner.authority.snapshot()
            #expect(!snapshot.outputsMuted && snapshot.pendingOutput == nil && snapshot.restoring == nil)
            let fresh = try await Owner.ticket(owner, Owner.windowOne)
            #expect(Owner.refusal(await owner.authority.redeemDirect(fresh)) == nil)
        }

        @Test func unplannedDropThenVerifiedReconnect() async throws {
            let owner = try await Owner.applying()
            let old = try await Owner.ticket(owner, Owner.windowOne)
            _ = try await owner.dropped().get()
            #expect(await owner.session == nil)
            #expect(Owner.refusal(try await Owner.admit(owner, Owner.windowOne)) == .gate(.unavailable(.recovering)))
            #expect(Owner.refusal(await owner.authority.redeemDirect(old)) == .recovering)

            let second = UUID()
            await owner.connected(session: second)
            _ = try await owner.beginApply(window: Owner.windowOne).get()
            await owner.verifiedReconnect(session: second)
            let restored = await owner.authority.snapshot()
            #expect(restored.restoring == nil && restored.queue.isEmpty)
            #expect(!restored.outputsMuted && restored.pendingOutput == nil)
            #expect(await owner.authority.lifecycle(of: owner.studio, window: Owner.windowOne) != .recovering)
            let fresh = try await Owner.ticket(owner, Owner.windowOne)
            #expect(Owner.refusal(await owner.authority.redeemDirect(fresh)) == nil)
        }

        @Test(arguments: [false, true])
        func noRestoreWithoutAVerifiedReconnect(verifyBeforeApply: Bool) async throws {
            let owner = try await Owner.applying()
            let first = try #require(await owner.session)
            _ = try await owner.dropped().get()
            let second = UUID()
            await owner.connected(session: second)
            await owner.verifiedReconnect(session: first)
            _ = try await owner.beginApply(window: Owner.windowOne).get()
            let pending = await owner.authority.snapshot()
            #expect(pending.restoring?.delivered == false && pending.outputsMuted)
            #expect(await owner.authority.lifecycle(of: owner.studio, window: Owner.windowOne) == .recovering)
            #expect(Owner.refusal(try await Owner.admit(owner, Owner.windowOne)) == .gate(.unavailable(.recovering)))

            // The verified input completes the restore whether it arrives before or after the apply.
            let verifiedOwner = try await Owner.applying()
            _ = try await verifiedOwner.dropped().get()
            await verifiedOwner.connected(session: second)
            if verifyBeforeApply { await verifiedOwner.verifiedReconnect(session: second) }
            _ = try await verifiedOwner.beginApply(window: Owner.windowOne).get()
            if !verifyBeforeApply { await verifiedOwner.verifiedReconnect(session: second) }
            #expect(Owner.refusal(try await Owner.admit(verifiedOwner, Owner.windowOne)) == nil)
        }

        @Test func demoModeHoldsNoLease() async throws {
            let owner = try await Owner.applying()
            let old = try await Owner.ticket(owner, Owner.windowOne)
            _ = try await owner.enteredDemoMode().get()
            let demo = await owner.authority.snapshot()
            #expect(demo.lease == nil && demo.queue.isEmpty && demo.restoring == nil)
            #expect(demo.pendingOutput == nil && !demo.outputsMuted)
            #expect(Owner.refusal(await owner.authority.redeemDirect(old)) == .staleLease)
            #expect(await owner.beginApply(window: Owner.windowOne) == .failure(.noSession))
            #expect(await owner.authority.snapshot().lease == nil)
        }

        @Test func closedRootRefusesUntilReopened() async throws {
            let owner = try await Owner.applying()
            let session = try #require(await owner.session)
            await owner.windowClosed(Owner.windowOne)
            #expect(await owner.beginApply(window: Owner.windowOne) == .failure(.windowClosed))
            #expect(await owner.authority.snapshot().lease?.windows == [])
            await owner.windowOpened(Owner.windowOne, generation: 0)
            #expect(await owner.beginApply(window: Owner.windowOne) == .success(session))
            #expect(await owner.authority.snapshot().lease?.windows == [Owner.windowOne])
            // Another window is never closed by windowOne's close or reopened by its open.
            await owner.windowClosed(Owner.windowOne)
            #expect(await owner.beginApply(window: Owner.windowTwo) == .success(session))
            #expect(await owner.authority.snapshot().lease?.windows == [Owner.windowTwo])
        }

        @Test func fenceAloneClosesTheRoot() async throws {
            let owner = try await Owner.owner()
            let session = UUID()
            await owner.connected(session: session)
            await owner.fenceApplies(for: Owner.windowOne, generation: 1)
            #expect(await owner.beginApply(window: Owner.windowOne) == .failure(.windowClosed))
            #expect(await owner.authority.snapshot().lease == nil)
            // The fence closes only its own window.
            #expect(await owner.beginApply(window: Owner.windowTwo) == .success(session))
            #expect(await owner.authority.snapshot().lease?.windows == [Owner.windowTwo])
        }

        @Test func neverOpenedWindowIsRefused() async throws {
            let owner = try HostAuthorityOwner(host: Owner.host)
            let never = WindowID(validated: "win.never")
            #expect(await owner.beginApply(window: never) == .failure(.noSession))
            await owner.connected(session: UUID())
            #expect(await owner.beginApply(window: never) == .failure(.windowClosed))
            #expect(await owner.authority.snapshot().lease == nil)
            // Closing it, or opening it with a stale generation, leaves no state behind.
            await owner.windowClosed(never)
            await owner.fenceApplies(for: never, generation: 1)
            await owner.windowOpened(never, generation: 0)
            await owner.windowClosed(never, generation: 1)
            #expect(await owner.openWindows.isEmpty)
            #expect(await owner.closureGenerations.isEmpty)
            #expect(await owner.beginApply(window: never) == .failure(.windowClosed))
        }

        @Test func closeReleasesOnlyItsOwnGeneration() async throws {
            let owner = try await Owner.applying()
            let session = try #require(await owner.session)
            for generation in UInt64(1)...3 {
                await owner.fenceApplies(for: Owner.windowOne, generation: generation)
                #expect(await owner.closureGenerations == [Owner.windowOne: generation])
                await owner.windowClosed(Owner.windowOne, generation: generation)
                #expect(await owner.closureGenerations.isEmpty)
                #expect(await owner.openWindows == [Owner.windowTwo])
                await owner.windowOpened(Owner.windowOne, generation: generation)
                #expect(await owner.beginApply(window: Owner.windowOne) == .success(session))
            }
            // A later detach's fence that lands before an earlier close survives that close.
            await owner.fenceApplies(for: Owner.windowOne, generation: 4)
            await owner.fenceApplies(for: Owner.windowOne, generation: 5)
            await owner.windowClosed(Owner.windowOne, generation: 4)
            #expect(await owner.closureGenerations == [Owner.windowOne: 5])
            await owner.windowOpened(Owner.windowOne, generation: 4)
            #expect(await owner.beginApply(window: Owner.windowOne) == .failure(.windowClosed))
            await owner.windowClosed(Owner.windowOne, generation: 5)
            #expect(await owner.closureGenerations.isEmpty)
            #expect(await owner.beginApply(window: Owner.windowOne) == .failure(.windowClosed))
            await owner.windowOpened(Owner.windowOne, generation: 5)
            #expect(await owner.beginApply(window: Owner.windowOne) == .success(session))
        }
    }
}

/// Builds isolated owners for the AU8a tests; production uses only `HostAuthorityOwner.shared`.
enum OwnerBench {
    static let host = HostID(validated: "host.owner")
    static let windowOne = WindowID(validated: "win.one")
    static let windowTwo = WindowID(validated: "win.two")

    /// A fresh owner whose roots `windowOne` and `windowTwo` are open; `granted` first grants the Host role (§9).
    static func owner(granted: Bool = true) async throws -> HostAuthorityOwner {
        let owner = try HostAuthorityOwner(host: host)
        await openRoots(owner)
        if granted { _ = try await owner.grant(.host).get() }
        return owner
    }

    /// A fresh owner, connected, whose `window` has run an apply gesture.
    static func applying(_ window: WindowID = windowOne, granted: Bool = true) async throws -> HostAuthorityOwner {
        let owner = try await owner(granted: granted)
        await owner.connected(session: UUID())
        _ = try await owner.beginApply(window: window).get()
        return owner
    }

    /// Both bench roots appeared: the owner refuses applies on a window that is not open (AU8c-1).
    static func openRoots(_ owner: HostAuthorityOwner) async {
        for window in [windowOne, windowTwo] { await owner.windowOpened(window, generation: 0) }
    }

    /// Admits the owner's current provider admission for `window`.
    static func admit(_ owner: HostAuthorityOwner,
                      _ window: WindowID) async throws -> Result<DirectWriteTicket?, DirectWriteRefusal> {
        await admit(owner, window, try #require(await owner.admission()))
    }

    static func admit(_ owner: HostAuthorityOwner, _ window: WindowID,
                      _ admission: WingApplyAdmission) async -> Result<DirectWriteTicket?, DirectWriteRefusal> {
        await owner.authority.admitDirect(admission.intent, admission: admission.admission,
                                          project: owner.studio, window: window)
    }

    static func ticket(_ owner: HostAuthorityOwner, _ window: WindowID) async throws -> DirectWriteTicket {
        try #require(try await admit(owner, window).get())
    }

    static func refusal<Success>(_ result: Result<Success, DirectWriteRefusal>) -> DirectWriteRefusal? {
        DirectSendBench.refusal(result)
    }
}
