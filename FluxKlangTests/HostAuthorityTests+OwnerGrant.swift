import Foundation
import Testing
@testable import FluxKlang

private typealias Owner = OwnerBench

extension HostAuthorityTests {
    /// AU8a (host-authority-sources.md §9): the owner's grant revision, epoch, single
    /// instance and window hooks. No WING, network or UI.
    struct OwnerGrant {
        @Test func firstGrantHasTheSpecifiedFingerprint() async throws {
            let owner = try await Owner.owner(granted: false)
            // Independently computed with Python hashlib.sha256, not PeerTrustDigest:
            // u64be(28) || domain UTF-8 || u64be(4) || "host" || u64be(8) || u64be(1).
            let expected = PermissionFingerprint(
                rawValue: "hp1.b45ceefcb58069fc6c1825aaea132b64dbfba80a42b27d1d18432511a7ab1dc5"
            )
            #expect(try await owner.grant(.host).get() == expected)
            #expect(await owner.permission == expected)
            #expect(await owner.authority.snapshot().live.permission == expected)
        }

        @Test func theRenderingWindowCanApplyAgain() async throws {
            let owner = try await Owner.applying()
            let session = try #require(await owner.session)
            let before = await owner.authority.snapshot()
            #expect(await owner.beginApply(window: Owner.windowOne) == .success(session))
            let after = await owner.authority.snapshot()
            #expect(after.lease?.windows == [Owner.windowOne])
            #expect(after.lease?.token == before.lease?.token)
            #expect(AuthorityBench.context(after) == AuthorityBench.context(before))
            let fresh = try await Owner.ticket(owner, Owner.windowOne)
            #expect(Owner.refusal(await owner.authority.redeemDirect(fresh)) == nil)
        }

        @Test func revokeThenRegrantStalesOldTickets() async throws {
            let owner = try await Owner.applying(granted: false)
            let first = try await owner.grant(.host).get()
            let old = try await Owner.ticket(owner, Owner.windowOne)
            let before = await owner.authority.snapshot()

            await owner.revoke()
            #expect(await owner.permission == nil)
            #expect(await owner.authority.snapshot().live.permission == nil)
            #expect(Owner.refusal(try await Owner.admit(owner, Owner.windowOne))
                    == .gate(.refused(.rejected(.permissionDenied))))

            let second = try await owner.grant(.host).get()
            #expect(first != second && first.isWellFormed && second.isWellFormed)
            #expect(await owner.grantRevision == 2)
            let regranted = await owner.authority.snapshot()
            #expect(regranted.live.permission == second)
            #expect(regranted.lease?.token == before.lease?.token)
            #expect(AuthorityBench.context(regranted) == AuthorityBench.context(before))
            #expect(Owner.refusal(await owner.authority.redeemDirect(old)) == .staleLive)
            let fresh = try await Owner.ticket(owner, Owner.windowOne)
            #expect(Owner.refusal(await owner.authority.redeemDirect(fresh)) == nil)
        }

        @Test func everyGrantRaisesTheRevision() async throws {
            let owner = try await Owner.owner(granted: false)
            #expect(await owner.grantRevision == 0)
            var minted: [PermissionFingerprint] = []
            for revision in UInt64(1)...4 {
                let fingerprint = try await owner.grant(.host).get()
                #expect(await owner.grantRevision == revision)
                #expect(await owner.permission == fingerprint)
                #expect(fingerprint == HostAuthorityOwner.fingerprint(.host, revision: revision))
                #expect(fingerprint.rawValue.hasPrefix("hp1.") && fingerprint.rawValue.utf8.count == 68)
                minted.append(fingerprint)
                if revision.isMultiple(of: 2) { await owner.revoke() }
            }
            #expect(Set(minted).count == minted.count && !minted.contains(HostAuthorityOwner.ungranted))
        }

        @Test func anExhaustedRevisionRefusesTheGrant() async throws {
            let owner = try HostAuthorityOwner(host: Owner.host, resumingGrantsAfter: .max - 1)
            let last = try await owner.grant(.host).get()
            #expect(await owner.grantRevision == .max)
            await owner.revoke()
            #expect(await owner.grant(.host) == .failure(.revisionExhausted))
            #expect(await owner.grantRevision == .max)
            #expect(await owner.permission == nil)
            #expect(await owner.authority.snapshot().live.permission == nil)
            #expect(last == HostAuthorityOwner.fingerprint(.host, revision: .max))
        }

        @Test func theEpochIsMintedOnce() async throws {
            let owner = try await Owner.owner(granted: false)
            #expect(owner.hostEpoch == HostEpoch(host: Owner.host, generation: .initial))
            #expect(owner.capabilities.host == Owner.host && owner.capabilities.hostEpoch == .initial)
            #expect(owner.capabilities.devices.isEmpty && owner.capabilities.routes.isEmpty)
            let steps: [(HostAuthorityOwner) async throws -> Void] = [
                { await $0.connected(session: UUID()) },
                { _ = try await $0.grant(.host).get() },
                { _ = try await $0.beginApply(window: Owner.windowOne).get() },
                { _ = try await $0.disconnected().get() },
                { await $0.connected(session: UUID()) },
                { _ = try await $0.beginApply(window: Owner.windowOne).get() },
                { _ = try await $0.dropped().get() },
                { await $0.revoke() },
                { _ = try await $0.enteredDemoMode().get() },
                { _ = try await $0.grant(.host).get() }
            ]
            for step in steps {
                try await step(owner)
                let live = await owner.authority.snapshot().live
                #expect(live.hostEpoch == owner.hostEpoch && live.capabilities == owner.capabilities)
            }
        }

        @Test func oneOwnerPerProcess() {
            let first = HostAuthorityOwner.shared
            let second = HostAuthorityOwner.shared
            #expect(first === second && first.authority === second.authority)
            #expect(first.hostEpoch == second.hostEpoch && first.studio == second.studio)
            #expect(first.hostEpoch.generation == .initial)
        }

        @Test func aNewWindowAttachesToAnUnattachedLease() async throws {
            let owner = try await Owner.applying()
            await owner.windowClosed(Owner.windowOne)
            let unattached = await owner.authority.snapshot()
            let token = try #require(unattached.lease?.token)
            #expect(unattached.lease?.windows.isEmpty == true)
            #expect(await owner.authority.lifecycle(of: owner.studio, window: Owner.windowTwo)
                    == .heldByOther(owner.studio))

            _ = try await owner.beginApply(window: Owner.windowTwo).get()
            let attached = await owner.authority.snapshot()
            #expect(attached.lease?.token == token && attached.lease?.windows == [Owner.windowTwo])
            #expect(AuthorityBench.context(attached) == AuthorityBench.context(unattached))
            let ticket = try await Owner.ticket(owner, Owner.windowTwo)
            #expect(Owner.refusal(await owner.authority.redeemDirect(ticket)) == nil)
        }

        @Test func windowCloseDropsItsTickets() async throws {
            let owner = try await Owner.applying()
            let token = try #require(await owner.authority.snapshot().lease?.token)
            let ticket = try await Owner.ticket(owner, Owner.windowOne)
            await owner.windowClosed(Owner.windowTwo)
            #expect(await owner.authority.outstandingDirectWriteCount() == 1)
            await owner.windowClosed(Owner.windowOne)
            #expect(await owner.authority.snapshot().lease?.token == token)
            #expect(Owner.refusal(await owner.authority.redeemDirect(ticket)) == .notOutstanding)
        }

        @Test func theProviderFeedsARealMinter() async throws {
            let owner = try await Owner.applying()
            let settings = try WingApplyBench.settings(3)
            let minter = WingApplyGrantMinter(authority: owner.authority, project: owner.studio,
                                              window: Owner.windowOne, budget: WingApplyTicketBudget(limit: 2),
                                              provider: owner.provider)
            let granted = await minter.grant(for: .remaining, targets: WingApplyBench.targets(settings))
            #expect(Owner.refusal(granted) == nil)
            await owner.revoke()
            let revoked = await minter.grant(for: .remaining, targets: WingApplyBench.targets(settings))
            #expect(Owner.refusal(revoked) == .gate(.refused(.rejected(.permissionDenied))))
        }

        @Test func revokeWaitsForADelayedGrantPublication() async throws {
            let pause = OwnerPublicationPause()
            let owner = try HostAuthorityOwner(host: Owner.host, publicationCheckpoint: { await pause.visit($0) })
            await owner.connected(session: UUID())
            _ = try await owner.beginApply(window: Owner.windowOne).get()
            let expected = HostAuthorityOwner.fingerprint(.host, revision: 1)
            let cached = try #require(HostAuthorityOwner.admission(epoch: owner.hostEpoch, permission: expected))
            let settings = try WingApplyBench.settings(3)
            let targets = WingApplyBench.targets(settings)
            let cachedMinter = WingApplyGrantMinter(
                authority: owner.authority, project: owner.studio, window: Owner.windowOne,
                budget: WingApplyTicketBudget(limit: 2), provider: { cached }
            )
            let freshMinter = WingApplyGrantMinter(
                authority: owner.authority, project: owner.studio, window: Owner.windowOne,
                budget: WingApplyTicketBudget(limit: 1), provider: owner.provider
            )
            // From here until both tasks are joined, assertions cannot throw.
            let grant = Task {
                let result = await owner.grant(.host)
                await pause.grantFinished()
                return result
            }
            guard await pause.next(waitingFor: "grant capture or completion") == .captured else {
                Issue.record("Grant completed before its captured-publication checkpoint")
                await pause.releaseAll()
                _ = await grant.value
                return
            }
            #expect(await owner.admission()?.intent.permission == cached.intent.permission)
            let revoke = Task {
                await owner.revoke()
                await pause.revokeFinished()
            }
            let progress = await pause.next(waitingFor: "revoke to join or complete")
            #expect(progress == .joining, "Revoke must join, not overtake, the delayed publisher")
            await pause.resume()
            let published = await pause.next(waitingFor: "grant publication or completion")
            #expect(published == .published, "Grant returned before its publication was observed")
            #expect(await pause.revoked == false)
            if await pause.revoked {
                // A competing publisher makes this the stale-grant window AFTER revoke returned.
                let refusal = Owner.refusal(await cachedMinter.grant(for: .remaining, targets: targets))
                #expect(refusal == .staleLive, "A cached admission must stay denied after revoke returns")
            }
            await pause.releaseAll()
            _ = await grant.value
            await revoke.value
            #expect(await owner.permission == nil)
            #expect(await owner.authority.snapshot().live.permission == nil)
            #expect(Owner.refusal(await cachedMinter.grant(for: .remaining, targets: targets)) == .staleLive)
            #expect(Owner.refusal(await freshMinter.grant(for: .remaining, targets: targets))
                    == .gate(.refused(.rejected(.permissionDenied))))
        }
    }
}

/// Completion events prevent missing checkpoints from leaving a test waiting on a finished operation.
private actor OwnerPublicationPause {
    enum Event { case captured, published, joining, grantFinished, revokeFinished }
    private let events = AsyncStream<Event>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var revoked = false

    func visit(_ point: HostAuthorityOwner.PublicationCheckpoint) async {
        guard !released else { return }
        switch point {
        case .captured(.some): await suspend(at: .captured)
        case .published(.some): await suspend(at: .published)
        case .joining: events.continuation.yield(.joining)
        default: break
        }
    }

    private func suspend(at event: Event) async {
        await withCheckedContinuation {
            continuation = $0
            events.continuation.yield(event)
        }
    }

    func next(waitingFor description: String) async -> Event? {
        // Failure cleanup only: cancellation alone cannot resume the publication continuation.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            Issue.record("Timed out waiting for \(description); releasing publication pause")
            releaseAll()
            events.continuation.finish()
        }
        var iterator = events.stream.makeAsyncIterator()
        let event = await iterator.next()
        watchdog.cancel()
        await watchdog.value
        return event
    }

    func grantFinished() { events.continuation.yield(.grantFinished) }

    func revokeFinished() {
        revoked = true
        events.continuation.yield(.revokeFinished)
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func releaseAll() {
        released = true
        resume()
    }
}
