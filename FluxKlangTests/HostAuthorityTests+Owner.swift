import Foundation
import Testing
@testable import FluxKlang

private typealias Owner = OwnerBench

extension HostAuthorityTests {
    /// AU8a (host-authority-sources.md §9): the owner's session, lease and recovery
    /// hooks against its real authority. No WING, network or UI.
    struct OwnerLifecycle {
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
            // Liveness of a never-opened window is not claimed: it is simply not closed.
            #expect(await owner.beginApply(window: Owner.windowTwo) == .success(session))
            #expect(await owner.authority.snapshot().lease?.windows == [Owner.windowTwo])
        }
    }
}

/// Builds isolated owners for the AU8a tests; production uses only `HostAuthorityOwner.shared`.
enum OwnerBench {
    static let host = HostID(validated: "host.owner")
    static let windowOne = WindowID(validated: "win.one")
    static let windowTwo = WindowID(validated: "win.two")

    /// A fresh owner; `granted` first grants the Host role (§9).
    static func owner(granted: Bool = true) async throws -> HostAuthorityOwner {
        let owner = try HostAuthorityOwner(host: host)
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
