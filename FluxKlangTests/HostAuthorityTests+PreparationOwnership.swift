import Testing
@testable import FluxKlang

/// Only inert fixtures and public admission. No scripted backend or bootstrap.
enum PreparationOwnershipBench {
    typealias Routing = AudioRoutingTestFixtures

    static func request(_ graph: GraphDocument) -> ActivationRequest {
        ActivationRequest(draft: .init(validated: "draft.owned"), graph: graph.id, baseRevision: graph.revision,
                          hostEpoch: AuthorityBench.hostEpoch, permission: AuthorityBench.permission,
                          digest: ActivationDigest(rawValue: "opaque-owned"), origin: .human)
    }

    static func authority(
        _ documents: Routing.Documents, capacity: Int = 1,
        limits: AudioRoutingLimits? = Routing.limits(frames: 4)
    ) async throws -> HostAuthority {
        let ledger = try GenerationLedger(primaryClock: .init(validated: "smp.owned"),
                                          musicalClock: nil, nominalRate: 48_000)
        let live = try AuthorityBench.liveState()
        let authority: HostAuthority
        if let limits {
            authority = try HostAuthority(host: ledger, live: live, prepareOnly: limits, planCapacity: capacity)
        } else {
            authority = try HostAuthority(host: ledger, live: live, planCapacity: capacity)
        }
        try await authority.open(project: documents.project.id,
                                 running: RunningGraph(revision: documents.graph.revision, prepared: nil)).get()
        return authority
    }

    static func begin(_ authority: HostAuthority, _ documents: Routing.Documents) async throws -> HostPrepare {
        try await authority.begin(request(documents.graph), candidate: documents.graph,
                                  projectDocument: documents.project, project: documents.project.id).get()
        return try #require(await authority.snapshot().outstanding[documents.project.id])
    }

    static func retain(_ authority: HostAuthority, _ identity: HostPrepare) async throws -> AudioRoutingLayout {
        let result = await authority.constructNextPreparation()
        guard case .retained(let actual, let layout) = result else {
            Issue.record("Expected real construction: \(result)")
            throw OwnedPreparationRefusal.missing
        }
        #expect(actual == identity)
        return layout
    }
}

private typealias Bench = PreparationOwnershipBench
private typealias Routing = AudioRoutingTestFixtures

extension HostAuthorityTests {
    struct PreparationOwnership {
        @Test func admissionReservationRejectsOverlapBeforeCanonicalMutation() async throws {
            let first = Routing.documents()
            var second = Routing.documents()
            second.project.id = AuthorityBench.projectB
            for constructed in [false, true] {
                for abandoned in [false, true] {
                    for replacement in [first, second] {
                        let authority = try await Bench.authority(first, capacity: 3)
                        try await authority.open(project: second.project.id,
                                                 running: RunningGraph(revision: .initial, prepared: nil)).get()
                        let identity = try await Bench.begin(authority, first)
                        if constructed { _ = await authority.constructNextPreparation() }
                        if abandoned { try await authority.abandonPrepare(project: first.project.id).get() }
                        let before = await authority.snapshot()
                        #expect(AuthorityBench.refusal(await authority.begin(
                            Bench.request(replacement.graph), candidate: replacement.graph,
                            projectDocument: replacement.project, project: replacement.project.id
                        )) == .preparationOccupied)
                        #expect(await authority.snapshot() == before)
                        if constructed {
                            #expect(await authority.disposePreparation(identity) ==
                                .disposed(abandoned ? .dropped : .routed))
                        } else {
                            if !abandoned { try await authority.abandonPrepare(project: first.project.id).get() }
                            #expect(await authority.constructNextPreparation() ==
                                .terminated(identity, .cancelled, .dropped))
                        }
                        let next = try await Bench.begin(authority, replacement)
                        #expect(next != identity)
                        #expect(next.attempt.generation == (replacement.project.id == first.project.id ?
                            try identity.attempt.generation.next() : .initial))
                        _ = try await Bench.retain(authority, next)
                        #expect(await authority.disposePreparation(next) == .disposed(.routed))
                    }
                }
            }
        }

        @Test func realSamplesRemainPendingAndPreserveCallerSnapshot() async throws {
            var documents = Routing.documents(map: [[0, 1, 0], [1, 1]])
            let original = documents
            let authority = try await Bench.authority(documents)
            #expect(await authority.constructNextPreparation() == .empty)
            let identity = try await Bench.begin(authority, documents)
            let admitted = await authority.snapshot()
            documents.project.roles.removeAll()
            documents.project.graphs.removeAll()
            documents.graph.edges.removeAll()
            documents.graph.nodes.removeAll()
            #expect(await authority.snapshot() == admitted)
            let layout = try await Bench.retain(authority, identity)
            let pending = await authority.snapshot()
            #expect(pending.plans == admitted.plans && pending.outstanding == admitted.outstanding)
            #expect(pending.queue.isEmpty)
            #expect(pending.projects[original.project.id]?.phase == .preparing)
            #expect(pending.projects[original.project.id]?.lifecycle == .preparing(
                try original.graph.revision.next(), over: .absent
            ))
            #expect(pending.projects[original.project.id]?.reviewed == nil)
            #expect(pending.projects[original.project.id]?.installed == nil)
            #expect(pending.projects[original.project.id]?.running.prepared == nil)
            let input: [Float] = [0.5, -1, 99, 99, -2, 0.25, 99, 99]
            for _ in 0..<3 {
                let block = try await authority.evaluatePreparation(identity, frames: 2, input: input).get()
                #expect(block.layout == layout && block.result == .processed)
                #expect(block.output == [-1, -1.75, 0, 0, -4, 0.5, 0, 0])
                #expect(block.peaks == [1.75, 4])
            }
            #expect(await authority.snapshot() == pending)
            #expect(await authority.disposePreparation(identity) == .disposed(.routed))
            let disposed = await authority.snapshot()
            #expect(disposed.plans.records[0].entries.isEmpty)
            #expect(disposed.projects[original.project.id]?.phase == .prepareFailed(.cancelled))
        }

        @Test func fixedStrideValidationAndRealNonfiniteSemantics() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents)
            let identity = try await Bench.begin(authority, documents)
            _ = try await Bench.retain(authority, identity)
            let before = await authority.snapshot()
            let original: [Float] = [-0.0, .leastNonzeroMagnitude, Float(1).nextUp, -4, 5, -6, 7, -8]
            var input = original
            let full = try await authority.evaluatePreparation(identity, frames: 4, input: input).get()
            #expect(full.result == .processed && full.output.map(\.bitPattern) == original.map(\.bitPattern))
            #expect(full.peaks == [4, 8])
            input[0] = 123
            var callerOutput = full.output
            var callerPeaks = full.peaks
            callerOutput[0] = 456
            callerPeaks[0] = 789
            #expect(callerOutput[0] == 456 && callerPeaks[0] == 789)
            #expect(full.output.map(\.bitPattern) == original.map(\.bitPattern))
            #expect(full.peaks == [4, 8])
            for frames in [-1, 5, Int.max] {
                #expect(await authority.evaluatePreparation(identity, frames: frames, input: []) ==
                    .failure(.invalidFrames))
            }
            for frames in [0, 1, 2, 4] {
                for count in [0, 2, 4, 7, 9] {
                    #expect(await authority.evaluatePreparation(
                        identity, frames: frames, input: [Float](repeating: 1, count: count)
                    ) == .failure(.invalidInputGeometry))
                }
            }
            let padded: [Float] = [1, -2, .nan, .infinity, -3, 4, .nan, .infinity]
            let short = try await authority.evaluatePreparation(identity, frames: 2, input: padded).get()
            #expect(short.result == .processed && short.output == [1, -2, 0, 0, -3, 4, 0, 0])
            #expect(short.peaks == [2, 4])
            #expect([2, 3, 6, 7].allSatisfy { short.output[$0].bitPattern == 0 })
            let zero = try await authority.evaluatePreparation(identity, frames: 0, input: padded).get()
            #expect(zero.result == .processed && zero.output == Array(repeating: 0, count: 8))
            #expect(zero.peaks == [0, 0])
            #expect((zero.output + zero.peaks).allSatisfy { $0.bitPattern == 0 })
            input = Array(original.reversed())
            let changed = try await authority.evaluatePreparation(identity, frames: 4, input: input).get()
            #expect(changed.result == .processed && changed.output.map(\.bitPattern) == input.map(\.bitPattern))
            #expect(changed.peaks == [8, 4])
            let refused = try await authority.evaluatePreparation(identity, frames: 4, input: padded).get()
            #expect(refused.result == .refused(.nonFiniteInput))
            #expect(refused.output == Array(repeating: 0, count: 8) && refused.peaks == [0, 0])
            #expect((refused.output + refused.peaks).allSatisfy { $0.bitPattern == 0 })
            #expect(try await authority.evaluatePreparation(identity, frames: 4, input: input).get() == changed)
            #expect(await authority.snapshot() == before)
            #expect(await authority.disposePreparation(identity) == .disposed(.routed))
            let next = try await Bench.begin(authority, documents)
            _ = try await Bench.retain(authority, next)
            input = Array(repeating: 11, count: 8)
            let later = try await authority.evaluatePreparation(next, frames: 4, input: input).get()
            #expect(later.result == .processed && later.output == input && later.peaks == [11, 11])
            #expect(await authority.disposePreparation(next) == .disposed(.routed))
            #expect(full.output.map(\.bitPattern) == original.map(\.bitPattern) && full.peaks == [4, 8])
            #expect(short.output == [1, -2, 0, 0, -3, 4, 0, 0] && short.peaks == [2, 4])
            #expect((zero.output + zero.peaks).allSatisfy { $0.bitPattern == 0 })
            #expect(changed.output.map(\.bitPattern) == original.reversed().map(\.bitPattern))
            #expect(changed.peaks == [8, 4])
        }

        @Test func realMuteAndOverflowAreNotSubstitutedByTheOwner() async throws {
            for muted in [false, true] {
                let documents = Routing.muteDocuments(muted)
                let authority = try await Bench.authority(documents)
                let identity = try await Bench.begin(authority, documents)
                _ = try await Bench.retain(authority, identity)
                let block = try await authority.evaluatePreparation(
                    identity, frames: 1, input: [2, 0, 0, 0, -3, 0, 0, 0]
                ).get()
                #expect(block.result == .processed)
                #expect(block.peaks == (muted ? [0, 0] : [2, 3]))
                #expect(await authority.disposePreparation(identity) == .disposed(.routed))
            }
            let documents = Routing.documents(map: [[0, 0], [1]])
            let authority = try await Bench.authority(documents)
            let identity = try await Bench.begin(authority, documents)
            _ = try await Bench.retain(authority, identity)
            let block = try await authority.evaluatePreparation(
                identity, frames: 1, input: [.greatestFiniteMagnitude, 0, 0, 0, 1, 0, 0, 0]
            ).get()
            #expect(block.result == .refused(.nonFiniteSum))
            #expect(block.output == Array(repeating: 0, count: 8) && block.peaks == [0, 0])
            #expect(await authority.disposePreparation(identity) == .disposed(.routed))
        }

        @Test func concurrentConstructionReservesOneSlot() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents)
            let identity = try await Bench.begin(authority, documents)
            let results = await withTaskGroup(of: OwnedPreparationStep.self) { group in
                for _ in 0..<12 { group.addTask { await authority.constructNextPreparation() } }
                var results: [OwnedPreparationStep] = []
                for await result in group { results.append(result) }
                return results
            }
            #expect(results.filter { if case .retained(identity, _) = $0 { return true }; return false }.count == 1)
            #expect(results.filter { $0 == .refused(.occupied) }.count == 11)
            let before = await authority.snapshot()
            #expect(await authority.constructNextPreparation() == .refused(.occupied))
            #expect(await authority.snapshot() == before)
            #expect(await authority.disposePreparation(identity) == .disposed(.routed))
        }

        @Test func abandonedCustodyWrongKeyAndCapacityReuse() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents)
            let identity = try await Bench.begin(authority, documents)
            _ = try await Bench.retain(authority, identity)
            let other = try await Bench.authority(documents)
            let wrong = try await Bench.begin(other, documents)
            let before = await authority.snapshot()
            #expect(await authority.disposePreparation(wrong) == .refused(.identityMismatch))
            #expect(await authority.evaluatePreparation(wrong, frames: 0, input: []) == .failure(.identityMismatch))
            #expect(await authority.snapshot() == before)
            try await authority.abandonPrepare(project: documents.project.id).get()
            let abandoned = await authority.snapshot()
            #expect(abandoned.plans.records[0].entries == [
                .init(attempt: identity.attempt, state: .pending(reclaim: true))
            ])
            #expect(await authority.evaluatePreparation(identity, frames: 0, input: []) == .failure(.unwanted))
            #expect(await authority.constructNextPreparation() == .refused(.occupied))
            #expect(AuthorityBench.refusal(await authority.begin(
                Bench.request(documents.graph), candidate: documents.graph,
                projectDocument: documents.project, project: documents.project.id
            )) == .preparationOccupied)
            #expect(await authority.snapshot() == abandoned)
            #expect(await authority.disposePreparation(identity) == .disposed(.dropped))
            #expect(await authority.disposePreparation(identity) == .refused(.missing))
            #expect(await authority.evaluatePreparation(identity, frames: 0, input: []) == .failure(.missing))
            let next = try await Bench.begin(authority, documents)
            #expect(next != identity)
            _ = try await Bench.retain(authority, next)
            let retained = await authority.snapshot()
            #expect(await authority.disposePreparation(identity) == .refused(.identityMismatch))
            #expect(await authority.evaluatePreparation(identity, frames: 0, input: []) == .failure(.identityMismatch))
            #expect(await authority.snapshot() == retained)
            #expect(await authority.disposePreparation(next) == .disposed(.routed))
            // Capacity reuse is bookkeeping evidence, NOT measured arena deallocation.
            try await other.abandonPrepare(project: documents.project.id).get()
            #expect(await other.constructNextPreparation() == .terminated(wrong, .cancelled, .dropped))
        }

        @Test func terminalDispositionRetainsRefusedAccountingWithoutAnotherAnswer() async throws {
            let documents = Routing.documents()
            for abandoned in [false, true] {
                // Genuine canonical identities and outcomes, with no processor or
                // book injection. This tests disposition, not physical deallocation.
                let legacy = try await Bench.authority(documents, limits: nil)
                let identity = try await Bench.begin(legacy, documents)
                #expect(await legacy.nextEngineCommand() == .prepare(
                    documents.graph, documents.project, identity.instance, identity.attempt
                ))
                if abandoned { try await legacy.abandonPrepare(project: documents.project.id).get() }
                let accepted = await legacy.prepareAnswered(
                    .failure(.cancelled), instance: identity.instance, attempt: identity.attempt
                )
                #expect(accepted == .success(abandoned ? .dropped : .routed))
                let refused = await legacy.prepareAnswered(
                    .failure(.cancelled), instance: identity.instance, attempt: identity.attempt
                )
                #expect(refused == .failure(.activation(.stalePrepareResponse)))
                let before = await legacy.snapshot()
                var lifetime = OwnedPreparationLifetime.cleaned(identity)
                #expect(lifetime.admissionRefusal == .preparationOccupied)
                var answers = 0
                for _ in 0..<3 {
                    // The same eligibility gate used before production's book call.
                    if let terminal = lifetime.terminalIdentity {
                        #expect(terminal == identity)
                        answers += 1
                        #expect(lifetime.finishTerminal(refused) ==
                            .faultAfterCleanup(.terminalAfterCleanup(identity)))
                    }
                    #expect(lifetime == .faulted(.terminalAfterCleanup(identity)))
                    #expect(lifetime.admissionRefusal == .preparationOwnerFaulted)
                    #expect(lifetime.terminalIdentity == nil)
                    #expect(lifetime.finishTerminal(accepted) == .refused(.faulted))
                }
                #expect(answers == 1)
                #expect(await legacy.snapshot() == before)
                var completed = OwnedPreparationLifetime.cleaned(identity)
                #expect(completed.finishTerminal(accepted) == .disposed(abandoned ? .dropped : .routed))
                #expect(completed == .vacant && completed.admissionRefusal == nil)
                #expect(completed.terminalIdentity == nil)
                #expect(completed.finishTerminal(refused) == .refused(.faulted))
                #expect(completed == .vacant)
            }
        }
    }
}

extension HostAuthorityTests {
    struct PreparationStorage {
        @Test func unusedMutedOverflowAndDisconnectedInputStillExecuteWithoutOutputs() async throws {
            for muted in [false, true] {
                var documents = Routing.muteDocuments(
                    muted, inputChannels: 3, inputMap: [[2], [0, 1, 2]]
                )
                documents.graph.nodes.removeAll { $0.kind == .roleOutput }
                documents.graph.edges.removeLast()
                try Routing.appendEndpoint(to: &documents, input: true, suffix: "zzz", channels: 1)
                let authority = try await Bench.authority(documents)
                let identity = try await Bench.begin(authority, documents)
                let layout = try await Bench.retain(authority, identity)
                #expect(layout.inputSampleCount == 16 && layout.outputSampleCount == 0 && layout.peakCount == 0)
                for bad in [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
                    var input = [Float](repeating: .nan, count: 16)
                    for channel in 0..<4 { input[channel * 4] = 1 }
                    if bad.isFinite {
                        input[0] = bad
                        input[4] = bad
                        input[8] = -bad // A finite final mathematical sum must not hide intermediate overflow.
                    } else {
                        input[12] = bad // Disconnected input still participates in validation.
                    }
                    let block = try await authority.evaluatePreparation(identity, frames: 1, input: input).get()
                    #expect(block.result == .refused(bad.isFinite ? .nonFiniteSum : .nonFiniteInput))
                    #expect(block.output.isEmpty && block.peaks.isEmpty)
                    for channel in 0..<4 { input[channel * 4] = -2 }
                    let recovered = try await authority.evaluatePreparation(identity, frames: 1, input: input).get()
                    #expect(recovered.result == .processed && recovered.output.isEmpty && recovered.peaks.isEmpty)
                }
                #expect(await authority.disposePreparation(identity) == .disposed(.routed))
            }
        }

        @Test func unequalAndOneSidedEmptyAndMuteOnlyGeometry() async throws {
            let unequal = Routing.documents(inputChannels: 3, outputChannels: 1, map: [[2, 0]])
            var inputOnly = Routing.documents()
            inputOnly.graph.nodes.removeAll { $0.kind == .roleOutput }
            inputOnly.graph.edges = []
            var outputOnly = Routing.documents()
            outputOnly.graph.nodes.removeAll { $0.kind == .roleInput }
            outputOnly.graph.edges = []
            var empty = Routing.documents()
            empty.graph.nodes = []
            empty.graph.edges = []
            var muteOnly = empty
            muteOnly.graph.nodes = [Routing.muteNode(true)]
            muteOnly.graph.requiredFeatures = [GraphDocument.constantMuteFeature]
            let limits = Routing.limits(frames: 16)
            #expect(try Routing.compile(empty, limits: limits).scratchBytes == 4)
            #expect(try Routing.compile(muteOnly, limits: limits).scratchBytes == 256)
            for documents in [unequal, inputOnly, outputOnly, empty, muteOnly] {
                let authority = try await Bench.authority(documents, limits: limits)
                let identity = try await Bench.begin(authority, documents)
                let layout = try await Bench.retain(authority, identity)
                let pending = await authority.snapshot()
                #expect(AuthorityBench.refusal(await authority.begin(
                    Bench.request(documents.graph), candidate: documents.graph,
                    projectDocument: documents.project, project: documents.project.id
                )) == .preparationOccupied)
                #expect(await authority.snapshot() == pending)
                for frames in [16, 1, 0, 16] {
                    var input = [Float](repeating: .nan, count: layout.inputSampleCount)
                    for channel in 0..<(layout.inputSampleCount / 16) {
                        for frame in 0..<frames { input[channel * 16 + frame] = Float(channel + 1) }
                    }
                    let block = try await authority.evaluatePreparation(identity, frames: frames, input: input).get()
                    #expect(block.result == .processed && block.layout == layout)
                    var expected = [Float](repeating: 0, count: layout.outputSampleCount)
                    if layout.inputs.count == 1 && layout.outputs.count == 1 {
                        for frame in 0..<frames { expected[frame] = 4 }
                    }
                    #expect(block.output.map(\.bitPattern) == expected.map(\.bitPattern))
                    #expect(block.peaks == (layout.inputSampleCount == 48 ?
                        [frames == 0 ? 0 : 4] : Array(repeating: 0, count: layout.peakCount)))
                }
                if layout.inputSampleCount > 0 {
                    #expect(try await authority.evaluatePreparation(
                        identity, frames: 1, input: Array(repeating: .nan, count: layout.inputSampleCount)
                    ).get().result == .refused(.nonFiniteInput))
                }
                #expect(await authority.disposePreparation(identity) == .disposed(.routed))
                #expect(await authority.disposePreparation(identity) == .refused(.missing))
            }
        }

        @Test func realConstructionExactBudgetsOneBelowAndArithmeticOverflow() async throws {
            let documents = Routing.documents()
            let exact = Routing.limits(frames: 4, inputs: 2, outputs: 2, terms: 2, scratch: 72, work: 60)
            let cases = [
                exact, Routing.limits(frames: 4, inputs: 1), Routing.limits(frames: 4, outputs: 1),
                Routing.limits(frames: 4, terms: 1), Routing.limits(frames: 4, scratch: 71),
                Routing.limits(frames: 4, work: 59), Routing.limits(frames: Int.max)
            ]
            for (index, limits) in cases.enumerated() {
                let authority = try await Bench.authority(documents, limits: limits)
                let identity = try await Bench.begin(authority, documents)
                if index == 0 {
                    _ = try await Bench.retain(authority, identity)
                    #expect(await authority.disposePreparation(identity) == .disposed(.routed))
                } else {
                    #expect(await authority.constructNextPreparation() ==
                        .terminated(identity, .engineRefused, .routed))
                    #expect(await authority.snapshot().plans.records[0].entries.isEmpty)
                }
            }
        }

        @Test func realInputOnlyReachesBothSixteenMiBRequests() async throws {
            var documents = Routing.documents(inputChannels: 64)
            documents.graph.nodes.removeAll { $0.kind == .roleOutput }
            documents.graph.edges = []
            for frames in [65_536, 65_537, Int.max] {
                for scratch in [(1 << 24) - 1, 1 << 24, Int.max] {
                    let limits = Routing.limits(
                        frames: frames, inputs: 64, outputs: 0, terms: 0, scratch: scratch, work: Int.max
                    )
                    let authority = try await Bench.authority(documents, limits: limits)
                    let identity = try await Bench.begin(authority, documents)
                    if frames != 65_536 || scratch < 1 << 24 {
                        #expect(await authority.constructNextPreparation() ==
                            .terminated(identity, .engineRefused, .routed))
                        continue
                    }
                    let layout = try await Bench.retain(authority, identity)
                    #expect(layout.inputSampleCount * MemoryLayout<Float>.stride == 1 << 24)
                    var input = [Float](repeating: 1, count: layout.inputSampleCount)
                    for value in [Float.nan, -0.0] {
                        input[input.count - 1] = value
                        let block = try await authority.evaluatePreparation(
                            identity, frames: frames, input: input
                        ).get()
                        #expect(block.result == (value.isFinite ? .processed : .refused(.nonFiniteInput)))
                        #expect(block.output.isEmpty && block.peaks.isEmpty)
                    }
                    #expect(await authority.disposePreparation(identity) == .disposed(.routed))
                }
            }
        }
    }
}
