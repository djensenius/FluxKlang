import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

/// An assembler on a fresh `.sysex` ring with prepared fault scopes, plus chunking helpers. Shared with
/// `RealtimeHandoffTests+SysExStress.swift`.
struct SysExFixture {
    static let base: UInt16 = 9
    let ring: SPSCRing<SysExMessageRef>
    let faults: FaultLatch
    let assembler: SysExAssembler

    init(sources: Int = 4, maximum: Int = 32, pool: Int = 128, ringCapacity: Int = 64,
         startingCursor: UInt64 = 0) throws {
        ring = try SPSCRing(policy: Root.sysexRingPolicy(capacity: ringCapacity))
        // Prepared neighbours on either side of the base catch a fault raised on the wrong handoff.
        let scopes = (0..<sources).map { FaultScope(handoff: Self.base, target: UInt32($0)) }
            + [FaultScope(handoff: Self.base &- 1, target: 0), FaultScope(handoff: Self.base &+ 1, target: 0)]
        faults = try FaultLatch(scopes: scopes)
        assembler = try SysExAssembler(sources: sources, maximumMessageBytes: maximum, poolBytes: pool,
                                       output: ring, faults: faults, scopeBase: Self.base,
                                       startingCursor: startingCursor)
    }

    func scope(_ source: UInt32) -> FaultScope { FaultScope(handoff: Self.base, target: source) }

    /// Acknowledges every prepared scope and returns the records that were latched.
    func takeFaults() -> [FaultRecord] {
        var scopes: [FaultScope] = []
        _ = faults.pending { scopes.append($0.scope) }
        return scopes.compactMap { faults.acknowledge($0) }
    }

    /// Sends `message` as UMP SysEx7 chunks of at most six bytes and returns each chunk's status.
    @discardableResult
    func send(_ message: [UInt8], source: UInt32 = 0, frame: Int64 = 0) -> [KernelStatus] {
        SysExFixture.chunks(message).map { status, slice in
            assembler.accept(source: source, status: status, bytes: Self.six(slice),
                             count: UInt8(slice.count), frame: frame)
        }
    }

    func chunk(_ status: SysExChunkStatus, _ bytes: [UInt8], source: UInt32 = 0) -> KernelStatus {
        assembler.accept(source: source, status: status, bytes: Self.six(bytes[...]), count: UInt8(bytes.count))
    }

    func drain() -> [(ref: SysExMessageRef, bytes: [UInt8])] {
        var messages: [(ref: SysExMessageRef, bytes: [UInt8])] = []
        while assembler.receive({ ref, bytes in messages.append((ref, Array(bytes))) }) == .ok {}
        return messages
    }

    static func chunks(_ message: [UInt8]) -> [(SysExChunkStatus, ArraySlice<UInt8>)] {
        guard message.count > 6 else { return [(.complete, message[...])] }
        let starts = Array(stride(from: 0, to: message.count, by: 6))
        return starts.enumerated().map { index, start in
            let slice = message[start..<min(start + 6, message.count)]
            let status: SysExChunkStatus = index == 0 ? .start : index == starts.count - 1 ? .end : .continue
            return (status, slice)
        }
    }

    /// Pads with 0x55 so a copy past `count` shows up as foreign bytes.
    static func six(_ slice: ArraySlice<UInt8>) -> SysExChunkBytes {
        let padded = Array(slice) + Array(repeating: 0x55, count: max(0, 6 - slice.count))
        return (padded[0], padded[1], padded[2], padded[3], padded[4], padded[5])
    }
}

extension RealtimeHandoffTests {
    /// A SysEx output ring: MIDI receive (verified single producer, as `SPSCRing` requires) to control.
    static func sysexRingPolicy(capacity: Int = 64) -> HandoffPolicy {
        policy(purpose: .sysex, producer: .midiReceive, producers: .init(maximum: 1, evidence: .verified),
               consumer: .control, capacity: capacity, ordering: .completeMessagesFIFO, deadline: .none)
    }

    /// Deterministic 7-bit message `sequence`, `length` bytes long.
    static func sysexMessage(_ sequence: UInt64, length: Int) -> [UInt8] {
        (0..<length).map { index in
            let mixed = (sequence &+ 1) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(index) &* 0xBF58_476D_1CE4_E5B9
            return UInt8(truncatingIfNeeded: mixed >> 33) & 0x7F
        }
    }

    struct SysExAssembly {
        @Test func startContinueEndAssemblesExactBytes() throws {
            let fixture = try SysExFixture()
            let lengths = [7, 12, 13, 18, 31, 32]
            for (sequence, length) in lengths.enumerated() {
                let statuses = fixture.send(Root.sysexMessage(UInt64(sequence), length: length))
                #expect(statuses.allSatisfy { $0 == .ok })
            }
            let messages = fixture.drain()
            #expect(messages.map(\.bytes) == lengths.enumerated().map { Root.sysexMessage(UInt64($0), length: $1) })
            #expect(messages.map { Int($0.ref.length) } == lengths)
            #expect(fixture.assembler.emittedCount == UInt64(lengths.count))
            #expect(fixture.takeFaults().isEmpty)
        }

        @Test func completeSingleChunkMessage() throws {
            let fixture = try SysExFixture()
            for length in 0...6 {
                #expect(fixture.send(Root.sysexMessage(UInt64(length), length: length)) == [.ok])
            }
            let messages = fixture.drain()
            #expect(messages.map(\.bytes) == (0...6).map { Root.sysexMessage(UInt64($0), length: $0) })
            #expect(messages.allSatisfy { $0.ref.source == 0 } && fixture.takeFaults().isEmpty)
        }

        @Test func sourcesAreIsolated() throws {
            let fixture = try SysExFixture()
            let first = Root.sysexMessage(1, length: 14)
            let second = Root.sysexMessage(2, length: 9)
            #expect(fixture.chunk(.start, Array(first[0..<6])) == .ok)
            #expect(fixture.chunk(.start, Array(second[0..<6]), source: 3) == .ok)
            #expect(fixture.chunk(.continue, Array(first[6..<12])) == .ok)
            #expect(fixture.chunk(.end, Array(second[6...]), source: 3) == .ok)
            #expect(fixture.chunk(.end, Array(first[12...])) == .ok)
            let messages = fixture.drain()
            #expect(messages.map(\.bytes) == [second, first])
            #expect(messages.map(\.ref.source) == [3, 0])
            // A fault on one source latches only that source's scope.
            #expect(fixture.chunk(.start, [1]) == .ok)
            #expect(fixture.chunk(.start, [2]) == .ok)
            #expect(fixture.faults.isLatched(fixture.scope(0)))
            #expect(!fixture.faults.isLatched(fixture.scope(3)))
            #expect(fixture.chunk(.end, [3], source: 3) == .refused(.notOwner))
            #expect(fixture.chunk(.end, [4]) == .ok)
            #expect(fixture.drain().map(\.bytes) == [[2, 4]])
        }

        @Test func overflowDiscardsAndRaisesScopedFault() throws {
            let fixture = try SysExFixture(maximum: 12)
            // Exactly the maximum is accepted, in one and in several chunks.
            #expect(fixture.send(Root.sysexMessage(1, length: 12), source: 2).allSatisfy { $0 == .ok })
            #expect(fixture.drain().map(\.bytes) == [Root.sysexMessage(1, length: 12)])
            // One byte more, arriving with `end`: the whole message is discarded, not truncated.
            #expect(fixture.send(Root.sysexMessage(2, length: 13), source: 2, frame: 77)
                    == [.ok, .ok, .refused(.invalidLength)])
            #expect(fixture.drain().isEmpty)
            #expect(fixture.takeFaults() == [FaultRecord(scope: fixture.scope(2), kind: .sysexOverflow, count: 1,
                                                         firstFrame: 77)])
            // Overflow in a `continue`: the rest of that message is swallowed without further faults.
            #expect(fixture.chunk(.start, Array(repeating: 1, count: 6), source: 2) == .ok)
            #expect(fixture.chunk(.continue, Array(repeating: 2, count: 6), source: 2) == .ok)
            #expect(fixture.chunk(.continue, [3], source: 2) == .refused(.invalidLength))
            #expect(fixture.chunk(.continue, [4], source: 2) == .refused(.invalidLength))
            #expect(fixture.chunk(.end, [5], source: 2) == .refused(.invalidLength))
            // That `end` closed the discarded message: a further `continue` is an orphan (one more fault).
            #expect(fixture.chunk(.continue, [6], source: 2) == .refused(.notOwner))
            #expect(fixture.drain().isEmpty)
            #expect(fixture.takeFaults().map { [$0.count] } == [[2]])
            // A single-chunk message longer than the maximum.
            let tiny = try SysExFixture(maximum: 4)
            #expect(tiny.send([1, 2, 3, 4, 5]) == [.refused(.invalidLength)])
            #expect(tiny.send([1, 2, 3, 4]) == [.ok])
            #expect(tiny.drain().map(\.bytes) == [[1, 2, 3, 4]])
            #expect(tiny.takeFaults().map(\.kind) == [.sysexOverflow])
            // The assembler recovers: the next message on the same source is delivered intact.
            #expect(fixture.send(Root.sysexMessage(3, length: 11), source: 2).allSatisfy { $0 == .ok })
            #expect(fixture.drain().map(\.bytes) == [Root.sysexMessage(3, length: 11)])
            #expect(fixture.assembler.discardedCount == 2)
        }

        @Test func startWhileAssemblingAbortsPreviousVisibly() throws {
            let fixture = try SysExFixture()
            #expect(fixture.chunk(.start, [1, 2, 3, 4, 5, 6], source: 1) == .ok)
            #expect(fixture.chunk(.start, [7, 8], source: 1) == .ok)
            #expect(fixture.chunk(.end, [9], source: 1) == .ok)
            #expect(fixture.drain().map(\.bytes) == [[7, 8, 9]])
            let records = fixture.takeFaults()
            #expect(records.map(\.scope) == [fixture.scope(1)])
            #expect(records.map(\.kind) == [.sysexAborted])
            // `complete` while a message is open also aborts it.
            #expect(fixture.chunk(.start, [1, 1, 1, 1, 1, 1], source: 1) == .ok)
            #expect(fixture.chunk(.complete, [2, 2], source: 1) == .ok)
            #expect(fixture.drain().map(\.bytes) == [[2, 2]])
            #expect(fixture.takeFaults().map(\.kind) == [.sysexAborted])
            #expect(fixture.assembler.discardedCount == 2)
        }

        @Test func continueWithoutStartIsRefused() throws {
            let fixture = try SysExFixture()
            #expect(fixture.chunk(.continue, [1, 2], source: 3) == .refused(.notOwner))
            #expect(fixture.chunk(.end, [3], source: 3) == .refused(.notOwner))
            #expect(fixture.drain().isEmpty)
            let records = fixture.takeFaults()
            #expect(records.map(\.scope) == [fixture.scope(3)])
            #expect(records.map(\.kind) == [.sysexAborted])
            #expect(records.map(\.count) == [2])
            // A completed message closes the source: a trailing `end` is an orphan too.
            #expect(fixture.send([4, 5], source: 3) == [.ok])
            #expect(fixture.chunk(.end, [6], source: 3) == .refused(.notOwner))
            #expect(fixture.drain().map(\.bytes) == [[4, 5]])
        }

        @Test func invalidCountAndSourceAreRefusedWithoutSideEffects() throws {
            let fixture = try SysExFixture(sources: 4)
            #expect(fixture.chunk(.start, [1, 2], source: 0) == .ok)
            for count: UInt8 in [7, 8, .max] {
                let status = fixture.assembler.accept(source: 0, status: .continue, bytes: (9, 9, 9, 9, 9, 9),
                                                      count: count)
                #expect(status == .refused(.invalidLength))
            }
            for source: UInt32 in [4, 5, .max] {
                for status in SysExChunkStatus.allCases {
                    let result = fixture.assembler.accept(source: source, status: status, bytes: (1, 1, 1, 1, 1, 1),
                                                          count: 1)
                    #expect(result == .refused(.slotOutOfRange))
                }
            }
            #expect(fixture.chunk(.end, [3]) == .ok)
            #expect(fixture.drain().map(\.bytes) == [[1, 2, 3]])
            #expect(fixture.takeFaults().isEmpty)
            #expect(fixture.faults.unknownScopeFaults == 0)
        }

        @Test func initRejectsInvalidConfiguration() throws {
            func failure(sources: Int = 4, maximum: Int = 32, pool: Int = 128,
                         ring: SPSCRing<SysExMessageRef>? = nil) throws -> SysExAssembler.PreparationError? {
                let output = try ring ?? SPSCRing(policy: Root.sysexRingPolicy())
                do {
                    _ = try SysExAssembler(sources: sources, maximumMessageBytes: maximum, poolBytes: pool,
                                           output: output, faults: FaultLatch(scopes: [.init(handoff: 0, target: 0)]),
                                           scopeBase: 0)
                    return nil
                } catch let error as SysExAssembler.PreparationError {
                    return error
                }
            }
            #expect(try failure() == nil)
            for sources in [Int.min, -1, 0, SysExAssembler.maximumSources + 1, .max] {
                #expect(try failure(sources: sources) == .sourcesOutOfRange(sources))
            }
            #expect(try failure(sources: SysExAssembler.maximumSources) == nil)
            for maximum in [Int.min, -1, 0, 65, .max] {
                #expect(try failure(maximum: maximum) == .maximumMessageBytesOutOfRange(maximum))
            }
            #expect(try failure(maximum: 64) == nil && failure(maximum: 1) == nil)
            for pool in [Int.min, 0, 1, 96, 129, SysExAssembler.maximumPoolBytes * 2, .max] {
                #expect(try failure(maximum: 1, pool: pool) == .poolBytesOutOfRange(pool))
            }
            #expect(try failure(maximum: 1, pool: 2) == nil)
            let events = try SPSCRing<SysExMessageRef>(policy: Root.policy(consumer: .control))
            #expect(try failure(ring: events) == .policy(.violates(.r8SysExSeparate)))
            let claimed = try SPSCRing<SysExMessageRef>(policy: Root.sysexRingPolicy())
            _ = claimed.makeProducer()
            #expect(try failure(ring: claimed) == .outputAlreadyClaimed)
            // The assembler claims the producer endpoint, so no second producer can.
            let fixture = try SysExFixture()
            let secondClaim = switch fixture.ring.makeProducer() {
            case .some: true
            case .none: false
            }
            #expect(!secondClaim)
        }

        @Test func sysexPolicyIsNotTelemetry() throws {
            let fixture = try SysExFixture()
            let policy = fixture.assembler.output.policy
            #expect(policy.purpose == .sysex && policy.ordering == .completeMessagesFIFO)
            #expect(policy.overflow == .refuseProducer)
            #expect(throws: SPSCRing<SysExMessageRef>.PreparationError.self) {
                try SPSCRing<SysExMessageRef>(policy: Root.telemetryPolicy())
            }
            #expect(Root.violation(Root.policy(purpose: .sysex, producers: .init(maximum: 1, evidence: .verified),
                                               consumer: .control, ordering: .latestOnly, deadline: .none,
                                               overflow: .overwriteLatest)) != nil)
        }

        @Test func valuesAreBitwiseCopyable() {
            Root.requireBitwise(SysExChunkStatus.self)
            Root.requireBitwise(SysExMessageRef.self)
            // UMP SysEx7 status nibble values.
            #expect(SysExChunkStatus.allCases.map(\.rawValue) == [0, 1, 2, 3])
        }
    }

    struct SysExPoolReuse {
        @Test func poolExhaustionRefusesAndRaisesOverflow() throws {
            let fixture = try SysExFixture(maximum: 8, pool: 16)
            #expect(fixture.send(Root.sysexMessage(1, length: 8), source: 1) == [.ok, .ok])
            #expect(fixture.send(Root.sysexMessage(2, length: 7), source: 1) == [.ok, .ok])
            // 15 of 16 bytes are unreleased: a 2-byte message does not fit and is refused, not overwritten.
            #expect(fixture.send([1, 2], source: 1, frame: 5) == [.refused(.full)])
            #expect(fixture.takeFaults() == [FaultRecord(scope: fixture.scope(1), kind: .sysexOverflow, count: 1,
                                                         firstFrame: 5)])
            #expect(fixture.assembler.discardedCount == 1)
            // Popping a ref is not a release: the pool stays full until the consumer acknowledges.
            let first = try #require(fixture.ring.tryPop())
            #expect(fixture.send([1, 2], source: 1) == [.refused(.full)])
            #expect(fixture.assembler.withMessage(first) { Array($0) } == Root.sysexMessage(1, length: 8))
            #expect(fixture.assembler.release(first) == .ok)
            #expect(fixture.send([3, 4], source: 1) == [.ok])
            #expect(fixture.drain().map(\.bytes) == [Root.sysexMessage(2, length: 7), [3, 4]])
        }

        @Test func outputRingFullRefusesAndKeepsAssemblerConsistent() throws {
            let fixture = try SysExFixture(pool: 128, ringCapacity: 1)
            #expect(fixture.send([1, 2, 3]) == [.ok])
            #expect(fixture.send([4, 5, 6], frame: 9) == [.refused(.full)])
            #expect(fixture.takeFaults().map(\.kind) == [.sysexOverflow])
            #expect(fixture.assembler.discardedCount == 1)
            let first = try #require(fixture.drain().first)
            #expect(first.bytes == [1, 2, 3])
            // The refused message took no pool space: the next one starts where the first ended.
            #expect(fixture.send([7, 8]) == [.ok])
            let next = try #require(fixture.drain().first)
            #expect(next.ref.offset == first.ref.offset + 3)
            #expect(next.bytes == [7, 8])
        }

        @Test func consumerReadsExactBytesThenReleaseAllowsReuse() throws {
            let fixture = try SysExFixture(maximum: 16, pool: 32)
            #expect(fixture.send(Root.sysexMessage(1, length: 10)).allSatisfy { $0 == .ok })
            #expect(fixture.send(Root.sysexMessage(2, length: 10), source: 2).allSatisfy { $0 == .ok })
            let first = try #require(fixture.ring.tryPop())
            let second = try #require(fixture.ring.tryPop())
            #expect(first == SysExMessageRef(sequence: 0, offset: 0, length: 10, source: 0))
            #expect(second == SysExMessageRef(sequence: 1, offset: 10, length: 10, source: 2))
            // Only the oldest unacknowledged message is readable or releasable; out-of-order, out-of-range and
            // other-lap refs are refused. (An altered length within the bound is not detectable; see `release`.)
            #expect(fixture.assembler.withMessage(second) { _ in 0 } == nil)
            #expect(fixture.assembler.release(second) == .refused(.notOwner))
            let forged = [SysExMessageRef(sequence: 0, offset: 0, length: 10, source: 4),
                          SysExMessageRef(sequence: 0, offset: 0, length: 17, source: 0),
                          SysExMessageRef(sequence: 0, offset: 32, length: 10, source: 0),
                          SysExMessageRef(sequence: 1, offset: 0, length: 10, source: 0)]
            for ref in forged { #expect(fixture.assembler.release(ref) == .refused(.notOwner)) }
            #expect(fixture.assembler.withMessage(first) { Array($0) } == Root.sysexMessage(1, length: 10))
            // Reading does not release; reading twice gives the same bytes.
            #expect(fixture.assembler.withMessage(first) { Array($0) } == Root.sysexMessage(1, length: 10))
            #expect(fixture.assembler.release(first) == .ok)
            #expect(fixture.assembler.release(first) == .refused(.notOwner))
            #expect(fixture.assembler.withMessage(second) { Array($0) } == Root.sysexMessage(2, length: 10))
            #expect(fixture.assembler.release(second) == .ok)
            // 20 of 32 bytes were used; a 14-byte message pads to the next lap and reuses released bytes.
            #expect(fixture.send(Root.sysexMessage(3, length: 14)).allSatisfy { $0 == .ok })
            let third = try #require(fixture.drain().first)
            #expect(third.ref.offset == 32)
            #expect(third.bytes == Root.sysexMessage(3, length: 14))
            #expect(fixture.assembler.receive { _, _ in } == .empty)
        }

        @Test func paddingAndEmptyMessagesCannotSkipOrRepeatAnAcknowledgement() throws {
            // Pool 16 from cursor 12: A (2 bytes) ends at 14, so B (5 bytes) pads to 16, the offset B would also
            // get if A were already acknowledged. Order comes from `sequence`, never from inferred placement.
            let fixture = try SysExFixture(maximum: 8, pool: 16, startingCursor: 12)
            #expect(fixture.send([1, 2]) == [.ok] && fixture.send([3, 4, 5, 6, 7]) == [.ok])
            #expect(fixture.send([]) == [.ok])
            let refs = (0..<3).compactMap { _ in fixture.ring.tryPop() }
            #expect(refs.map(\.offset) == [12, 16, 21] && refs.map(\.sequence) == [12, 13, 14])
            #expect(fixture.assembler.withMessage(refs[1]) { _ in 0 } == nil)
            #expect(fixture.assembler.release(refs[1]) == .refused(.notOwner))
            for (ref, bytes) in zip(refs, [[1, 2], [3, 4, 5, 6, 7], []] as [[UInt8]]) {
                #expect(fixture.assembler.withMessage(ref) { Array($0) } == bytes)
                #expect(fixture.assembler.release(ref) == .ok)
                // A repeated acknowledgement, even of an empty message, is refused.
                #expect(fixture.assembler.release(ref) == .refused(.notOwner))
            }
            #expect(fixture.send([8, 9]) == [.ok] && fixture.drain().map(\.bytes) == [[8, 9]])
        }

        @Test(arguments: [UInt64(0), UInt64.max])
        func receiveKeepsARefItCannotDeliverYetAndRecovers(startingCursor: UInt64) throws {
            let fixture = try SysExFixture(startingCursor: startingCursor)
            #expect(fixture.send([1]) == [.ok] && fixture.send([2]) == [.ok] && fixture.send([3]) == [.ok])
            let first = try #require(fixture.ring.tryPop())
            // `first` is still unacknowledged: `receive` keeps the ref it popped and dequeues nothing more.
            var delivered: [[UInt8]] = []
            for _ in 0..<3 {
                #expect(fixture.assembler.receive { delivered.append(Array($1)) } == .refused(.notOwner))
            }
            #expect(fixture.assembler.withMessage(first) { Array($0) } == [1])
            #expect(fixture.assembler.release(first) == .ok)
            while fixture.assembler.receive({ delivered.append(Array($1)) }) == .ok {}
            #expect(delivered == [[2], [3]] && fixture.assembler.receive { _, _ in } == .empty)
        }

        @Test func consumerCallsInsideABodyAreRefused() throws {
            let fixture = try SysExFixture()
            #expect(fixture.send([1, 2]) == [.ok] && fixture.send([3]) == [.ok])
            var nested: [KernelStatus] = []
            var inner: Int? = 0
            #expect(fixture.assembler.receive { ref, bytes in
                nested = [fixture.assembler.release(ref), fixture.assembler.receive { _, _ in }]
                inner = fixture.assembler.withMessage(ref) { $0.count }
                nested.append(Array(bytes) == [1, 2] ? .ok : .empty)
            } == .ok)
            #expect(nested == [.refused(.notOwner), .refused(.notOwner), .ok] && inner == nil)
            let second = try #require(fixture.ring.tryPop())
            let nestedRelease = fixture.assembler.withMessage(second) { _ in fixture.assembler.release(second) }
            #expect(nestedRelease == .refused(.notOwner))
            #expect(fixture.assembler.release(second) == .ok && fixture.assembler.receive { _, _ in } == .empty)
        }

        @Test(arguments: [0, UInt64.max - 300])
        func poolWrapsAcrossManyLapsAndUInt64Boundary(start: UInt64) throws {
            let fixture = try SysExFixture(sources: 3, maximum: 24, pool: 64, startingCursor: start)
            var previousEnd = start
            for sequence in 0..<1_000 as Range<UInt64> {
                let length = Int(sequence * 7 % 25)
                let message = Root.sysexMessage(sequence, length: length)
                #expect(fixture.send(message, source: UInt32(sequence % 3)).allSatisfy { $0 == .ok })
                let delivered = fixture.drain()
                #expect(delivered.map(\.bytes) == [message])
                guard let ref = delivered.first?.ref else { continue }
                #expect(ref.source == UInt32(sequence % 3))
                // Contiguous with the previous message, or padded to the next 64-byte lap.
                let gap = ref.offset &- previousEnd
                #expect(gap == 0 || (gap < 64 && (ref.offset & 63) == 0))
                previousEnd = ref.offset &+ UInt64(length)
            }
            #expect((previousEnd &- start) / 64 > 100)
            #expect(fixture.assembler.emittedCount == 1_000)
            #expect(fixture.takeFaults().isEmpty)
        }
    }
}
