import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
struct ProductionAccessAuditTests {
    @Test func mirrorsRemainAdditiveAndSameRecorderIsNotDuplicated() {
        let primary = ProductionAccessAudit()
        let mirror = ProductionAccessAudit()
        primary.record(.attempted, for: .wingTransport, mirroring: mirror)
        #expect(primary.snapshot().count(.attempted, for: .wingTransport) == 1)
        #expect(mirror.snapshot().count(.attempted, for: .wingTransport) == 1)

        primary.record(.denied, for: .wingTransport, mirroring: primary)
        #expect(primary.snapshot().count(.denied, for: .wingTransport) == 1)
        #expect(mirror.snapshot().count(.denied, for: .wingTransport) == 0)

        primary.record(.factoryEvaluated, for: .wingTransport, mirroring: nil)
        #expect(primary.snapshot().count(.factoryEvaluated, for: .wingTransport) == 1)
        #expect(mirror.snapshot().count(.factoryEvaluated, for: .wingTransport) == 0)
    }

    @Test func eventsAndOperationsStayDistinctInIndependentRecorders() {
        let audit = ProductionAccessAudit()
        let other = ProductionAccessAudit()
        audit.record(.attempted, for: .wingTransport)
        audit.record(.attempted, for: .wingTransport)
        audit.record(.denied, for: .wingTransport)
        audit.record(.factoryEvaluated, for: .midiInput)
        audit.record(.passiveConstruction, for: .midiInput)
        audit.record(.apiEntered, for: .localNetworkProbe)

        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .wingTransport) == 2)
        #expect(snapshot.count(.denied, for: .wingTransport) == 1)
        #expect(snapshot.count(.factoryEvaluated, for: .wingTransport) == 0)
        #expect(snapshot.count(.attempted, for: .midiInput) == 0)
        #expect(snapshot.count(.factoryEvaluated, for: .midiInput) == 1)
        #expect(snapshot.count(.passiveConstruction, for: .midiInput) == 1)
        #expect(snapshot.count(.apiEntered, for: .midiInput) == 0)
        #expect(snapshot.count(.apiEntered, for: .localNetworkProbe) == 1)
        #expect(other.snapshot().count(.attempted, for: .wingTransport) == 0)
    }

    @Test func constructionCaptureIncludesArgumentEvaluationAndRetainsImmutableBoundaries() {
        let audit = ProductionAccessAudit()
        audit.record(.attempted, for: .wingTransport)
        func argument() -> Int {
            audit.record(.factoryEvaluated, for: .midiInput)
            return 7
        }
        let construction = audit.captureConstruction {
            ConstructedService(input: argument(), audit: audit)
        }

        #expect(construction.value.input == 7)
        #expect(construction.checkpoint.before.count(.attempted, for: .wingTransport) == 1)
        #expect(construction.checkpoint.before.count(.factoryEvaluated, for: .midiInput) == 0)
        #expect(construction.checkpoint.before.count(.passiveConstruction, for: .midiInput) == 0)
        #expect(construction.checkpoint.after.count(.factoryEvaluated, for: .midiInput) == 1)
        #expect(construction.checkpoint.after.count(.passiveConstruction, for: .midiInput) == 1)

        audit.record(.apiEntered, for: .midiInput)
        audit.record(.factoryEvaluated, for: .midiInput)
        #expect(construction.checkpoint.after.count(.apiEntered, for: .midiInput) == 0)
        #expect(construction.checkpoint.after.count(.factoryEvaluated, for: .midiInput) == 1)
        #expect(audit.snapshot().count(.apiEntered, for: .midiInput) == 1)
        #expect(audit.snapshot().count(.factoryEvaluated, for: .midiInput) == 2)
    }

    @Test func concurrentWritersKeepEveryEventAndCoherentSnapshots() async {
        let audit = ProductionAccessAudit()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<256 {
                        audit.record(.attempted, for: .localNetworkProbe)
                        audit.record(.denied, for: .localNetworkProbe)
                        let snapshot = audit.snapshot()
                        #expect(snapshot.count(.attempted, for: .localNetworkProbe)
                                >= snapshot.count(.denied, for: .localNetworkProbe))
                    }
                }
            }
        }
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .localNetworkProbe) == 2_048)
        #expect(snapshot.count(.denied, for: .localNetworkProbe) == 2_048)
        #expect(snapshot.count(.apiEntered, for: .localNetworkProbe) == 0)
    }
}

private struct ConstructedService {
    let input: Int

    init(input: Int, audit: ProductionAccessAudit) {
        self.input = input
        audit.record(.passiveConstruction, for: .midiInput)
    }
}
