import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests

/// Hand-typed fixtures; no number here comes from the catalog's own formulas.
private enum Fixture {
    /// A: events, 256 slots, reserve 32, stride 32 -> 8192 bytes.
    static let eventsPolicy = Root.policy(overflow: .reservedCritical(reserved: 32))
    /// B: telemetry, 64 slots, stride 100 -> 6400 bytes.
    static let telemetryPolicy = Root.policy(
        purpose: .telemetry, producer: .render, consumer: .ui, capacity: 64, ordering: .latestOnly,
        deadline: .none, overflow: .overwriteLatest)
    /// C: sysex, 100 slots, stride 40 -> 4000 bytes.
    static let sysexPolicy = Root.policy(
        purpose: .sysex, producer: .midiReceive, producers: .conservativeDefault(for: .midiReceive),
        consumer: .control, capacity: 100, ordering: .completeMessagesFIFO, deadline: .none)
    static let goldenTotal = 18_592
    static let hugeStride = 1 << 61

    static func queue(_ name: String, _ policy: HandoffPolicy = eventsPolicy, notes: Bool = false,
                      stride: Int = 8) -> KernelQueueDeclaration {
        KernelQueueDeclaration(name: name, policy: policy, carriesNotes: notes, elementStride: stride)
    }

    static func events(capacity: Int, reserved: Int) -> HandoffPolicy {
        Root.policy(capacity: capacity, overflow: .reservedCritical(reserved: reserved))
    }

    static func fanIn(capacity: Int, reserved: Int, lanes: Int = 64,
                      ordering: HandoffOrdering = .fifoPerProducer) -> HandoffPolicy {
        Root.policy(producer: .midiReceive, producers: .init(maximum: lanes, evidence: .verified),
                    capacity: capacity, ordering: ordering, overflow: .reservedCritical(reserved: reserved))
    }

    static var golden: [KernelQueueDeclaration] {
        [queue("events", eventsPolicy, notes: true, stride: 32), queue("telemetry", telemetryPolicy, stride: 100),
         queue("sysex", sysexPolicy, stride: 40)]
    }

    static func numbered(_ count: Int) -> [KernelQueueDeclaration] {
        (0..<count).map { queue("q" + String($0), stride: 1) }
    }

    static func refusal(_ declarations: [KernelQueueDeclaration],
                        budget: Int = .max) -> KernelQueueCatalogRefusal? {
        do throws(KernelQueueCatalogRefusal) {
            _ = try KernelQueueCatalog.make(declarations: declarations, byteBudget: budget)
            return nil
        } catch {
            return error
        }
    }

    static func catalog(_ declarations: [KernelQueueDeclaration], budget: Int = .max) throws -> KernelQueueCatalog {
        try KernelQueueCatalog.make(declarations: declarations, byteBudget: budget)
    }

    static func noteRefusal(_ policy: HandoffPolicy) -> KernelQueueCatalogRefusal? {
        refusal([queue("note", policy, notes: true)])
    }
}

extension RealtimeHandoffTests {
    struct CatalogTotals {
        @Test func kernelQueueCatalogEmptyListWithValidBudgetIsAnEmptyCatalog() throws {
            let catalog = try Fixture.catalog([], budget: 1)
            let count = catalog.declarations.count
            #expect(count == 0)
            #expect(catalog.totalBytes == 0)
            #expect(catalog.headroomBytes == 1)
            #expect(catalog.bytes(at: 0) == nil)
            #expect(catalog.index(ofName: "events") == nil)
        }

        @Test func kernelQueueCatalogGoldenThreeQueuesTotalEighteenThousandFiveHundredNinetyTwo() throws {
            let catalog = try Fixture.catalog(Fixture.golden, budget: 20_000)
            #expect(catalog.totalBytes == 18_592)
            #expect(catalog.byteBudget == 20_000)
            #expect(catalog.headroomBytes == 1_408)
            #expect(catalog.bytes(at: 0) == 8_192)
            #expect(catalog.bytes(at: 1) == 6_400)
            #expect(catalog.bytes(at: 2) == 4_000)
            let kept = catalog.declarations
            #expect(kept == Fixture.golden)
        }

        @Test func kernelQueueCatalogBudgetEqualToTotalIsAcceptedAndOneLessIsOverBudget() throws {
            let exact = try Fixture.catalog(Fixture.golden, budget: 18_592)
            #expect(exact.headroomBytes == 0)
            let short = Fixture.refusal(Fixture.golden, budget: 18_591)
            #expect(short == .overBudget(totalBytes: 18_592, byteBudget: 18_591))
        }

        @Test func kernelQueueCatalogByteBudgetBelowOneIsRefusedAndOneIsAccepted() throws {
            for budget in [0, -1, Int.min] {
                #expect(Fixture.refusal([], budget: budget) == .invalidByteBudget(budget))
            }
            let one = try Fixture.catalog([], budget: 1)
            #expect(one.byteBudget == 1)
            let tiny = Fixture.refusal(Fixture.golden, budget: 1)
            #expect(tiny == .overBudget(totalBytes: 18_592, byteBudget: 1))
        }

        @Test func kernelQueueCatalogAcceptsTwoHundredFiftySixQueuesAndRefusesTwoHundredFiftySeven() throws {
            let full = try Fixture.catalog(Fixture.numbered(256))
            let count = full.declarations.count
            #expect(count == 256)
            #expect(full.totalBytes == 65_536)
            #expect(full.index(ofName: "q255") == 255)
            #expect(Fixture.refusal(Fixture.numbered(257)) == .tooManyQueues(257))
        }

        @Test func kernelQueueCatalogQueueBytesOverflowAndTheLargestFittingStride() throws {
            let wide = Fixture.queue("wide", Root.policy(capacity: 65_536), stride: .max)
            #expect(Fixture.refusal([wide]) == .queueBytesOverflow(index: 0))
            let single = Fixture.queue("single", Root.policy(capacity: 1), stride: .max)
            let one = try Fixture.catalog([single])
            #expect(one.totalBytes == Int.max)
            let fitting = Int.max / 65_536
            let fits = Fixture.queue("fits", Root.policy(capacity: 65_536), stride: fitting)
            let catalog = try Fixture.catalog([fits])
            #expect(catalog.totalBytes == 9_223_372_036_854_710_272)
            let beyond = Fixture.queue("beyond", Root.policy(capacity: 65_536), stride: fitting + 1)
            #expect(Fixture.refusal([beyond]) == .queueBytesOverflow(index: 0))
        }

        @Test func kernelQueueCatalogRunningTotalOverflowIsRefusedAndAnExactIntMaxIsAccepted() throws {
            let half = Root.policy(capacity: 2)
            let first = Fixture.queue("first", half, stride: Fixture.hugeStride)
            let second = Fixture.queue("second", half, stride: Fixture.hugeStride)
            #expect(Fixture.refusal([first, second]) == .totalBytesOverflow(index: 1))
            let rest = Fixture.queue("rest", Root.policy(capacity: 1), stride: (1 << 62) - 1)
            let exact = try Fixture.catalog([first, rest])
            #expect(exact.totalBytes == Int.max)
            #expect(exact.headroomBytes == 0)
            let past = Fixture.queue("past", Root.policy(capacity: 1), stride: 1 << 62)
            #expect(Fixture.refusal([first, past]) == .totalBytesOverflow(index: 1))
        }

        @Test func kernelQueueCatalogLookupsAnswerNilOutsideTheDeclaredRange() throws {
            let catalog = try Fixture.catalog(Fixture.golden)
            #expect(catalog.index(ofName: "events") == 0)
            #expect(catalog.index(ofName: "sysex") == 2)
            for missing in ["", "Events", "event", "events ", String(repeating: "a", count: 65)] {
                #expect(catalog.index(ofName: missing) == nil)
            }
            for outside in [-1, 3, Int.min, Int.max] {
                #expect(catalog.bytes(at: outside) == nil)
            }
            #expect(catalog.bytes(at: 2) == 4_000)
        }

        @Test func kernelQueueCatalogEqualInputsGiveEqualCatalogsAndABudgetChangeDiffers() throws {
            let first = try Fixture.catalog(Fixture.golden, budget: 20_000)
            let again = try Fixture.catalog(Fixture.golden, budget: 20_000)
            let roomier = try Fixture.catalog(Fixture.golden, budget: 20_001)
            let reordered = try Fixture.catalog(Fixture.golden.reversed(), budget: 20_000)
            #expect(first == again)
            #expect(first != roomier)
            #expect(first != reordered)
            #expect(reordered.index(ofName: "events") == 2)
        }
    }

    struct CatalogDeclarations {
        @Test func kernelQueueCatalogNameGrammarAcceptsLowercaseLeadsAndTheTailBytes() throws {
            let valid = ["a", "z", "a0", "a9", "az", "a.", "a_", "a-", "a.b_c-9", "events.ring-2_x"]
            for name in valid {
                #expect(Fixture.refusal([Fixture.queue(name)]) == nil)
            }
            let catalog = try Fixture.catalog([Fixture.queue("a.b_c-9")])
            #expect(catalog.index(ofName: "a.b_c-9") == 0)
        }

        @Test func kernelQueueCatalogNameGrammarRefusesBytesOutsideTheGrammar() {
            let invalid = ["`a", "{a", "@a", "[a", "Aa", "0a", "9a", ".a", "_a", "-a", "a b", "a`", "a{", "a/", "a:",
                           "a@", "aA", "aZ", "a[", "a\u{e9}", "e\u{301}", "\u{e9}", "a\n", "a\u{0}", "a\u{FF21}"]
            for name in invalid {
                #expect(Fixture.refusal([Fixture.queue(name)]) == .invalidName(index: 0))
            }
        }

        @Test func kernelQueueCatalogNameLengthAcceptsSixtyFourBytesAndRefusesSixtyFiveAndEmpty() throws {
            let longest = "b" + String(repeating: "c", count: 63)
            let catalog = try Fixture.catalog([Fixture.queue(longest)])
            #expect(catalog.index(ofName: longest) == 0)
            let tooLong = longest + "c"
            #expect(Fixture.refusal([Fixture.queue(tooLong)]) == .invalidName(index: 0))
            #expect(Fixture.refusal([Fixture.queue("")]) == .invalidName(index: 0))
            let huge = String(repeating: "d", count: 100_000)
            #expect(Fixture.refusal([Fixture.queue(huge)]) == .invalidName(index: 0))
        }

        @Test func kernelQueueCatalogStrideBelowOneIsRefusedAndOneIsAccepted() throws {
            for stride in [0, -1, Int.min] {
                let refused = Fixture.refusal([Fixture.queue("a"), Fixture.queue("b", stride: stride)])
                #expect(refused == .invalidElementStride(index: 1, stride: stride))
            }
            let one = try Fixture.catalog([Fixture.queue("a", stride: 1)])
            #expect(one.totalBytes == 256)
        }

        @Test func kernelQueueCatalogPolicyViolationOfEachRuleIsReportedWithTheQueueIndex() {
            let cases: [(HandoffPolicy, HandoffPolicyRule)] = [
                (Root.policy(consumers: 2), .r1SingleConsumer),
                (Root.policy(producers: .init(maximum: 0, evidence: .appOwned)), .r2Cardinality),
                (Root.policy(capacity: 0), .r3Capacity),
                (Root.policy(ordering: .latestOnly), .r4LatestOnly),
                (Root.telemetryPolicy(consumer: .render), .r5TelemetryNotRender),
                (Root.policy(deadline: .none), .r6RenderDeadline),
                (Root.policy(overflow: .reservedCritical(reserved: 0)), .r7Reserve),
                (Root.sysexPolicy(ordering: .fifo), .r8SysExSeparate)
            ]
            for (policy, rule) in cases {
                let refused = Fixture.refusal([Fixture.queue("ok"), Fixture.queue("bad", policy)])
                #expect(refused == .policy(index: 1, .violates(rule)))
            }
        }

        @Test func kernelQueueCatalogReserveOfSixteenIsAcceptedAtCapacitySeventeenAndRefusedAsPolicyAtSixteen() {
            let derived = OverflowPolicy.defaultCriticalReserve(capacity: 17)
            #expect(derived == .reservedCritical(reserved: 16))
            #expect(OverflowPolicy.defaultCriticalReserve(capacity: 16) == nil)
            #expect(Fixture.noteRefusal(Fixture.events(capacity: 17, reserved: 16)) == nil)
            let tight = Fixture.noteRefusal(Fixture.events(capacity: 16, reserved: 16))
            #expect(tight == .policy(index: 0, .violates(.r7Reserve)))
        }

        @Test func kernelQueueCatalogReserveBelowSixteenIsRefusedForNotesAndAcceptedWithoutNotes() {
            for reserved in [1, 8, 15] {
                let policy = Fixture.events(capacity: 256, reserved: reserved)
                #expect(Fixture.noteRefusal(policy) == .noteReserve(index: 0, .reserveBelowMinimum(reserved)))
                #expect(Fixture.refusal([Fixture.queue("plain", policy)]) == nil)
            }
            for reserved in [16, 17, 255] {
                #expect(Fixture.noteRefusal(Fixture.events(capacity: 256, reserved: reserved)) == nil)
            }
        }

        @Test func kernelQueueCatalogNoteQueueWithRefusingOverflowLacksItsReserve() {
            let refusing = Root.policy(overflow: .refuseProducer)
            #expect(Fixture.noteRefusal(refusing) == .noteReserve(index: 0, .reserveMissing))
            #expect(Fixture.refusal([Fixture.queue("plain", refusing)]) == nil)
            let later = Fixture.refusal([Fixture.queue("lead"), Fixture.queue("note", refusing, notes: true)])
            #expect(later == .noteReserve(index: 1, .reserveMissing))
        }

        @Test func kernelQueueCatalogNoteQueueOutsideTheEventsPurposeIsRefused() {
            let retire = Root.policy(purpose: .retire, producer: .render, consumer: .control, deadline: .none,
                                     overflow: .reservedCritical(reserved: 32))
            let others = [Fixture.sysexPolicy, Fixture.telemetryPolicy, retire]
            for policy in others {
                #expect(Fixture.noteRefusal(policy) == .noteReserve(index: 0, .notAnEventsQueue))
                #expect(Fixture.refusal([Fixture.queue("plain", policy)]) == nil)
            }
        }

        @Test func kernelQueueCatalogFanInWithoutPerProducerOrderingIsRefusedForNotes() {
            let fifo = Fixture.fanIn(capacity: 1_088, reserved: 1_024, ordering: .fifo)
            #expect(Fixture.noteRefusal(fifo) == .noteReserve(index: 0, .multiProducerNeedsPerProducerLanes))
            #expect(Fixture.refusal([Fixture.queue("plain", fifo)]) == nil)
            #expect(Fixture.noteRefusal(Fixture.fanIn(capacity: 1_088, reserved: 1_024)) == nil)
        }

        @Test func kernelQueueCatalogFanInLaneDivisibilityIsCheckedForCapacityAndReserve() {
            let capacityOff = Fixture.fanIn(capacity: 1_089, reserved: 1_024)
            #expect(Fixture.noteRefusal(capacityOff) == .noteReserve(index: 0, .lanesDoNotDivide))
            let reserveOff = Fixture.fanIn(capacity: 1_088, reserved: 1_025)
            #expect(Fixture.noteRefusal(reserveOff) == .noteReserve(index: 0, .lanesDoNotDivide))
            let twoLanes = Fixture.fanIn(capacity: 100, reserved: 33, lanes: 2)
            #expect(Fixture.noteRefusal(twoLanes) == .noteReserve(index: 0, .lanesDoNotDivide))
            #expect(Fixture.refusal([Fixture.queue("plain", reserveOff)]) == nil)
        }

        @Test func kernelQueueCatalogFanInReserveIsCheckedPerLaneAtFifteenAndSixteen() {
            let fifteen = Fixture.fanIn(capacity: 1_088, reserved: 960)
            #expect(Fixture.noteRefusal(fifteen) == .noteReserve(index: 0, .reserveBelowMinimum(15)))
            #expect(Fixture.noteRefusal(Fixture.fanIn(capacity: 1_088, reserved: 1_024)) == nil)
            let twoLanes = Fixture.fanIn(capacity: 100, reserved: 30, lanes: 2)
            #expect(Fixture.noteRefusal(twoLanes) == .noteReserve(index: 0, .reserveBelowMinimum(15)))
            #expect(Fixture.noteRefusal(Fixture.fanIn(capacity: 100, reserved: 32, lanes: 2)) == nil)
            let single = Fixture.fanIn(capacity: 100, reserved: 16, lanes: 1)
            #expect(Fixture.noteRefusal(single) == nil)
        }

        @Test func kernelQueueCatalogNoteQueueAfterOtherQueuesPassesTheDuplicateAndTotalChecks() throws {
            let note = Fixture.queue("notes", Fixture.events(capacity: 100, reserved: 16), notes: true, stride: 4)
            let queues = [Fixture.queue("a"), Fixture.queue("b"), note]
            let catalog = try Fixture.catalog(queues)
            #expect(catalog.index(ofName: "notes") == 2)
            #expect(catalog.bytes(at: 2) == 400)
            #expect(catalog.totalBytes == 4_496)
            #expect(Fixture.refusal(queues + [Fixture.queue("notes")]) == .duplicateName(index: 3))
        }

        @Test func kernelQueueCatalogDuplicateNameIsRefusedAtTheLaterIndexAndUppercaseIsRefusedAsInvalidName() {
            let queues = [Fixture.queue("a"), Fixture.queue("b"), Fixture.queue("a")]
            #expect(Fixture.refusal(queues) == .duplicateName(index: 2))
            let adjacent = [Fixture.queue("x"), Fixture.queue("x")]
            #expect(Fixture.refusal(adjacent) == .duplicateName(index: 1))
            #expect(Fixture.refusal([Fixture.queue("a"), Fixture.queue("A")]) == .invalidName(index: 1))
            #expect(Fixture.refusal([Fixture.queue("a"), Fixture.queue("a0")]) == nil)
        }
    }

    struct CatalogOrder {
        @Test func kernelQueueCatalogBudgetDefectIsReportedBeforeTheQueueCount() {
            let refused = Fixture.refusal(Fixture.numbered(257), budget: 0)
            #expect(refused == .invalidByteBudget(0))
        }

        @Test func kernelQueueCatalogQueueCountIsReportedBeforeAnyDeclarationDefect() {
            let queues = [Fixture.queue("Bad")] + Fixture.numbered(256)
            #expect(Fixture.refusal(queues) == .tooManyQueues(257))
        }

        @Test func kernelQueueCatalogNameDefectIsReportedBeforeAStrideDefect() {
            let refused = Fixture.refusal([Fixture.queue("Bad", stride: 0)])
            #expect(refused == .invalidName(index: 0))
        }

        @Test func kernelQueueCatalogStrideDefectIsReportedBeforeAPolicyViolation() {
            let refused = Fixture.refusal([Fixture.queue("ok", Root.policy(consumers: 2), stride: 0)])
            #expect(refused == .invalidElementStride(index: 0, stride: 0))
        }

        @Test func kernelQueueCatalogPolicyViolationIsReportedBeforeANoteDefect() {
            let both = Root.policy(consumers: 2, overflow: .reservedCritical(reserved: 8))
            #expect(Fixture.noteRefusal(both) == .policy(index: 0, .violates(.r1SingleConsumer)))
        }

        @Test func kernelQueueCatalogNoteDefectIsReportedBeforeAQueueBytesOverflow() {
            let policy = Root.policy(capacity: 65_536, overflow: .reservedCritical(reserved: 8))
            let refused = Fixture.refusal([Fixture.queue("big", policy, notes: true, stride: .max)])
            #expect(refused == .noteReserve(index: 0, .reserveBelowMinimum(8)))
        }

        @Test func kernelQueueCatalogQueueBytesOverflowIsReportedBeforeADuplicateName() {
            let big = Root.policy(capacity: 65_536)
            let refused = Fixture.refusal([Fixture.queue("same"), Fixture.queue("same", big, stride: .max)])
            #expect(refused == .queueBytesOverflow(index: 1))
        }

        @Test func kernelQueueCatalogDuplicateNameIsReportedBeforeARunningTotalOverflow() {
            let half = Root.policy(capacity: 2)
            let first = Fixture.queue("same", half, stride: Fixture.hugeStride)
            let second = Fixture.queue("same", half, stride: Fixture.hugeStride)
            let other = Fixture.queue("other", half, stride: Fixture.hugeStride)
            #expect(Fixture.refusal([first, other]) == .totalBytesOverflow(index: 1))
            #expect(Fixture.refusal([first, second]) == .duplicateName(index: 1))
        }

        @Test func kernelQueueCatalogEarlierDeclarationDefectWinsOverALaterOne() {
            let big = Root.policy(capacity: 65_536)
            let overflow = Fixture.queue("big", big, stride: .max)
            let badName = Fixture.queue("Bad")
            #expect(Fixture.refusal([overflow, badName]) == .queueBytesOverflow(index: 0))
            #expect(Fixture.refusal([badName, overflow]) == .invalidName(index: 0))
        }

        @Test func kernelQueueCatalogDeclarationDefectIsReportedBeforeAnOverBudgetTotal() {
            let refused = Fixture.refusal([Fixture.queue("a", stride: 1_000), Fixture.queue("Bad")], budget: 10)
            #expect(refused == .invalidName(index: 1))
            let over = Fixture.refusal([Fixture.queue("a", stride: 1_000)], budget: 10)
            #expect(over == .overBudget(totalBytes: 256_000, byteBudget: 10))
        }

        @Test func kernelQueueCatalogNoteChecksRunInTheirPinnedOrderWhenSeveralDefectsHold() {
            let sysexRefusing = Fixture.noteRefusal(Fixture.sysexPolicy)
            #expect(sysexRefusing == .noteReserve(index: 0, .notAnEventsQueue))
            let missingAndFifo = Root.policy(producer: .midiReceive, producers: .init(maximum: 64, evidence: .verified))
            #expect(Fixture.noteRefusal(missingAndFifo) == .noteReserve(index: 0, .reserveMissing))
            let fifoAndOdd = Fixture.fanIn(capacity: 1_089, reserved: 1_025, ordering: .fifo)
            #expect(Fixture.noteRefusal(fifoAndOdd) == .noteReserve(index: 0, .multiProducerNeedsPerProducerLanes))
            let oddAndLow = Fixture.fanIn(capacity: 1_088, reserved: 1_000)
            #expect(Fixture.noteRefusal(oddAndLow) == .noteReserve(index: 0, .lanesDoNotDivide))
        }
    }
}
