import Testing
@testable import FluxKlang

private let projectA = AuthorityBench.projectA
private let projectB = AuthorityBench.projectB
private let projectC = AuthorityBench.projectC
private let windowA = AuthorityBench.windowA
private let windowA2 = AuthorityBench.windowA2
private let windowB = AuthorityBench.windowB
private let liveParameter = ParameterID(validated: "parameter.live")
private let setLive = CommandOperation.set(liveParameter, ParameterValue(value: 0.5, unit: .normalized))
private let panic = CommandOperation.panic
private let editDraft = CommandOperation.editDraft(DraftID(validated: "draft.main"))
private let otherPermission = PermissionFingerprint(rawValue: "permissions.next")

private func nextEpoch() throws -> HostEpoch {
    HostEpoch(host: AuthorityBench.host, generation: try Generation.initial.next())
}

/// Admits every scope used here; `liveParameter` is the one live parameter.
private func admission(epoch: HostEpoch = AuthorityBench.hostEpoch,
                       permission: PermissionFingerprint = AuthorityBench.permission) throws -> AdmissionContext {
    let descriptor = try ParameterDescriptor(.init(
        id: liveParameter, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: 0.8, curve: .linear,
        ramp: ParameterRamp(.init(kind: .linear, minimumMilliseconds: 10, maximumMilliseconds: 100)),
        controlClass: .live, verification: .reported
    ))
    let scopes: Set<CommandScope> = [.parameter(liveParameter), .safety, .draft(DraftID(validated: "draft.main"))]
    return AdmissionContext(hostEpoch: epoch, connectionEpoch: nil, revisions: CommandRevisions(),
                            permission: permission, allowedScopes: scopes,
                            allowedClasses: Set(ControlClass.allCases), catalog: try ParameterCatalog([descriptor]))
}

/// A running-set `.set` by default; `panic` and `editDraft` need no ticket.
private func intent(_ operation: CommandOperation = setLive, epoch: HostEpoch = AuthorityBench.hostEpoch,
                    origin: CommandOrigin = .human,
                    granted: PermissionFingerprint = AuthorityBench.permission) throws -> CommandIntent {
    try CommandIntent(.init(
        id: CommandID(validated: "command.direct"), commandClass: operation.controlClass ?? .live, origin: origin,
        hostEpoch: epoch, connectionEpoch: nil, revisions: CommandRevisions(), operation: operation,
        permission: granted
    ))
}

/// Admits a running-set `.set` from `window` of `project`, requiring a ticket.
private func ticket(_ authority: HostAuthority, project: ProjectID = projectA,
                    window: WindowID = windowA) async throws -> DirectWriteTicket {
    try #require(try await authority.admitDirect(try intent(), admission: try admission(),
                                                 project: project, window: window).get())
}

/// Expects admission refused as `expected`, with the snapshot and outstanding count unchanged.
private func expectAdmitRefused(_ authority: HostAuthority, _ refused: CommandIntent,
                                admission context: AdmissionContext? = nil, project: ProjectID = projectA,
                                window: WindowID = windowA, _ expected: DirectWriteRefusal,
                                sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let before = await authority.snapshot()
    let count = await authority.outstandingDirectWriteCount()
    let result = await authority.admitDirect(refused, admission: try context ?? admission(),
                                             project: project, window: window)
    #expect(refusal(result) == expected, sourceLocation: sourceLocation)
    #expect(await authority.snapshot() == before, sourceLocation: sourceLocation)
    #expect(await authority.outstandingDirectWriteCount() == count, sourceLocation: sourceLocation)
}

/// Expects a safety or draft intent admitted without a ticket, changing nothing.
private func expectNoTicketNeeded(_ authority: HostAuthority, _ operation: CommandOperation,
                                  project: ProjectID, window: WindowID,
                                  sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let before = await authority.snapshot()
    let count = await authority.outstandingDirectWriteCount()
    let result = await authority.admitDirect(try intent(operation), admission: try admission(),
                                             project: project, window: window)
    #expect(try result.get() == nil, sourceLocation: sourceLocation)
    #expect(await authority.snapshot() == before, sourceLocation: sourceLocation)
    #expect(await authority.outstandingDirectWriteCount() == count, sourceLocation: sourceLocation)
}

/// Redeems `ticket`, expecting `expected` (nil: success), the snapshot unchanged and
/// the outstanding count down by exactly one unless it was not outstanding. A
/// refused ticket can never be retried.
private func expectRedeem(_ authority: HostAuthority, _ ticket: DirectWriteTicket,
                          _ expected: DirectWriteRefusal? = nil,
                          sourceLocation: SourceLocation = #_sourceLocation) async {
    let before = await authority.snapshot()
    let count = await authority.outstandingDirectWriteCount()
    #expect(refusal(await authority.redeemDirect(ticket)) == expected, sourceLocation: sourceLocation)
    #expect(await authority.snapshot() == before, sourceLocation: sourceLocation)
    let consumed = expected == .notOutstanding ? 0 : 1
    #expect(await authority.outstandingDirectWriteCount() == count - consumed, sourceLocation: sourceLocation)
    guard expected != .notOutstanding else { return }
    #expect(refusal(await authority.redeemDirect(ticket)) == .notOutstanding, sourceLocation: sourceLocation)
    #expect(await authority.outstandingDirectWriteCount() == count - 1, sourceLocation: sourceLocation)
}

private func refusal<Success>(_ result: Result<Success, DirectWriteRefusal>) -> DirectWriteRefusal? {
    if case .failure(let refusal) = result { return refusal }
    return nil
}

private func live(epoch: HostEpoch = AuthorityBench.hostEpoch,
                  permission: PermissionFingerprint? = AuthorityBench.permission) throws -> HostLiveState {
    let base = try AuthorityBench.liveState(epoch: epoch)
    return HostLiveState(hostEpoch: base.hostEpoch, permission: permission, capabilities: base.capabilities)
}

extension HostAuthorityTests {
    /// AU1: single-use, lease-, live- and context-fenced direct-write tickets.
    struct DirectWrite {
        @Test func onlyARenderingWindowGetsARunningSetTicket() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let before = await authority.snapshot()
            for (project, window) in [(projectB, windowB), (projectA, windowA2)] {
                try await expectAdmitRefused(authority, try intent(), project: project, window: window,
                                             .gate(.unavailable(.heldByOther(projectA))))
                try await expectNoTicketNeeded(authority, panic, project: project, window: window)
                try await expectNoTicketNeeded(authority, editDraft, project: project, window: window)
            }
            try await expectAdmitRefused(authority, try intent(), project: projectC, .unknownProject)
            let issued = try await ticket(authority)
            #expect(await authority.outstandingDirectWriteCount() == 1)
            let lease = try await AuthorityBench.leaseToken(authority)
            #expect(issued.project == projectA && issued.window == windowA && issued.lease == lease)
            #expect(issued.scope == .parameter(liveParameter) && issued.context == AuthorityBench.context(before))
            #expect(issued.hostEpoch == AuthorityBench.hostEpoch && issued.permission == AuthorityBench.permission)
            let second = try await ticket(authority)
            #expect(second.serial != issued.serial)
            #expect(await authority.snapshot() == before)
            await expectRedeem(authority, issued)
            await expectRedeem(authority, issued, .notOutstanding)
            await expectRedeem(authority, second)
        }

        @Test func noLeaseHolderGrantsNoDirectWrite() async throws {
            let authority = try await AuthorityBench.makeAuthority(holding: nil)
            for (project, window) in [(projectA, windowA), (projectB, windowB)] {
                #expect(await authority.lifecycle(of: project, window: window) == .stopped)
                try await expectAdmitRefused(authority, try intent(), project: project, window: window,
                                             .windowCannotWrite(.stopped))
                try await expectNoTicketNeeded(authority, panic, project: project, window: window)
            }
        }

        /// Intended: the holder's rendering window owns the engine even while its
        /// project lifecycle is `.stopped`, and `admit` accepts the command.
        @Test func aStoppedHolderIsGrantedATicket() async throws {
            let authority = try await AuthorityBench.makeAuthority(lifecycleA: .stopped)
            #expect(await authority.lifecycle(of: projectA, window: windowA) == .stopped)
            let issued = try await ticket(authority)
            await expectRedeem(authority, issued)
        }

        @Test func gateRefusalsPassThroughBeforeTheRole() async throws {
            let cases: [(CommandIntent, CommandResult)] = [
                (try intent(epoch: try nextEpoch()), .stale(.hostEpoch)),
                (try intent(granted: otherPermission), .rejected(.permissionChanged)),
                (try intent(origin: .assistant), .rejected(.permissionDenied))
            ]
            let stopped = try await AuthorityBench.makeAuthority(holding: nil)
            let held = try await AuthorityBench.makeAuthority()
            for (authority, project, window) in [(stopped, projectA, windowA), (held, projectB, windowB),
                                                 (held, projectA, windowA)] {
                for (refused, result) in cases {
                    try await expectAdmitRefused(authority, refused, project: project, window: window,
                                                 .gate(.refused(result)))
                }
            }
        }

        @Test func admissionMustMatchTheLiveState() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let epoch = try nextEpoch()
            // The gate admits an intent that matches its own context; the book refuses
            // a context that is not live.
            try await expectAdmitRefused(authority, try intent(epoch: epoch), admission: try admission(epoch: epoch),
                                         .staleLive)
            try await expectAdmitRefused(authority, try intent(granted: otherPermission),
                                         admission: try admission(permission: otherPermission), .staleLive)
            // Safety stays available whatever the context.
            let panicked = await authority.admitDirect(try intent(panic, epoch: epoch),
                                                       admission: try admission(epoch: epoch),
                                                       project: projectA, window: windowA)
            #expect(try panicked.get() == nil)
        }

        @Test func liveChangesStaleTheTicket() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let bumped = try await ticket(authority)
            await authority.updateLive(try live(epoch: try nextEpoch()))
            await expectRedeem(authority, bumped, .staleLive)
            await authority.updateLive(try live())
            let revoked = try await ticket(authority)
            await authority.updateLive(try live(permission: otherPermission))
            await expectRedeem(authority, revoked, .staleLive)
            // Valid again, but each refused attempt consumed its ticket.
            await authority.updateLive(try live())
            await expectRedeem(authority, revoked, .notOutstanding)
            await expectRedeem(authority, bumped, .notOutstanding)
        }

        @Test func leaseChangesStaleTheTicket() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transferred = try await ticket(authority)
            _ = try await authority.transfer(to: projectB, window: windowB).get()
            await expectRedeem(authority, transferred, .staleLease)
            _ = try await authority.transfer(to: projectA, window: windowA).get()

            let released = try await ticket(authority)
            try await authority.release(project: projectA).get()
            await expectRedeem(authority, released, .staleLease)

            _ = try await authority.acquire(project: projectA, window: windowA).get()
            let reacquired = try await ticket(authority)
            try await authority.release(project: projectA).get()
            _ = try await authority.acquire(project: projectA, window: windowA).get()
            #expect(await authority.lifecycle(of: projectA, window: windowA) == .running)
            await expectRedeem(authority, reacquired, .staleLease)
        }

        @Test func aWindowReusedByAnotherProjectIsStale() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await ticket(authority)
            _ = try await authority.transfer(to: projectB, window: windowB).get()
            try await authority.attach(windowA, project: projectB).get()
            let reused = await authority.snapshot().lease
            #expect(reused?.project == projectB && reused?.windows == [windowA, windowB])
            await expectRedeem(authority, issued, .staleLease)
        }

        @Test func detachDropsTheWindowsTickets() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            try await authority.attach(windowA2, project: projectA).get()
            let detached = try await ticket(authority)
            let kept = try await ticket(authority, window: windowA2)
            try await authority.detach(windowA).get()
            #expect(await authority.outstandingDirectWriteCount() == 1)
            await expectRedeem(authority, detached, .notOutstanding)
            try await authority.attach(windowA, project: projectA).get()
            await expectRedeem(authority, detached, .notOutstanding)
            await expectRedeem(authority, kept)
        }

        @Test func aCommitInFlightThenItsContextBumpRefuse() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await AuthorityBench.makeAuthority(&engine)
            let during = try await ticket(authority)
            let after = try await ticket(authority)
            let lease = await authority.snapshot().lease
            _ = try await AuthorityBench.commitDelivered(authority, &engine)
            let delivered = await authority.snapshot()
            #expect(delivered.inFlight[projectA] != nil && AuthorityBench.context(delivered) == during.context)
            await expectRedeem(authority, during, .commitInFlight)
            _ = try #require(await engine.report(authority, .succeeded)).verdict.get()
            let reported = await authority.snapshot()
            #expect(reported.lease == lease && reported.inFlight.isEmpty)
            #expect(AuthorityBench.context(reported) != after.context)
            await expectRedeem(authority, after, .staleContext)
        }

        @Test func recoveryRefusesRedemption() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let issued = try await ticket(authority)
            try await authority.leaseLost(try await AuthorityBench.leaseToken(authority)).get()
            await expectRedeem(authority, issued, .recovering)
            try await expectAdmitRefused(authority, try intent(), .gate(.unavailable(.recovering)))
        }

        @Test func capacityRefusesUntilTicketsGoStale() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            var issued: [DirectWriteTicket] = []
            for _ in 0..<HostAuthority.directWriteCapacity { issued.append(try await ticket(authority)) }
            try await expectAdmitRefused(authority, try intent(), .tooManyOutstanding)
            // Redeeming frees a slot.
            await expectRedeem(authority, try #require(issued.first))
            issued.append(try await ticket(authority))
            // A lease change stales every outstanding ticket; they no longer hold the cap.
            try await authority.release(project: projectA).get()
            _ = try await authority.acquire(project: projectA, window: windowA).get()
            var fresh: [DirectWriteTicket] = []
            for _ in 0..<HostAuthority.directWriteCapacity { fresh.append(try await ticket(authority)) }
            #expect(await authority.outstandingDirectWriteCount() == HostAuthority.directWriteCapacity)
            #expect(Set(fresh.map(\.serial)).count == fresh.count)
            #expect(Set((issued + fresh).map(\.serial)).count == issued.count + fresh.count)
            try await expectAdmitRefused(authority, try intent(), .tooManyOutstanding)
            await expectRedeem(authority, try #require(issued.last), .notOutstanding)
            await expectRedeem(authority, try #require(fresh.last))
        }
    }
}
