import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// swiftlint:disable type_name
extension PeerControlMessageTests {
    typealias F = Fixture

    static func isMalformed<Value>(_ outcome: Outcome<Value>) -> Bool {
        if case .failure(.malformed) = outcome { return true }
        return false
    }

    @Test func everyPrefixOfEveryGoldenMessageIsMalformed() throws {
        for (index, golden) in F.goldens.enumerated() {
            for length in 0..<golden.bytes.count {
                let outcome = F.decode(Array(golden.bytes.prefix(length)))
                #expect(Self.isMalformed(outcome), "golden \(index) prefix \(length)")
            }
        }
    }

    @Test func everyPrefixOfStructurallyRichMessagesIsMalformed() {
        let messages: [PeerControlMessage] = [
            F.command(F.intent(operation: .ramp(F.pid("p"), F.value(0.5), milliseconds: 250), connection: false)),
            F.command(F.intent(operation: .locate(ticks: 44_100), permission: "pé")),
            F.result(.admitted), F.result(.inFlight),
            F.result(.replayed(.applied(revisions: F.revisions))),
            F.result(.replayed(.refused(.applied))),
            F.result(.refused(.ledgerFull(capacity: 7))),
            F.result(.refused(.command(.stale(.generation(F.generationKey(.cancelScope, "g")))))),
            F.result(.refused(.command(.rejected(.invalidValue(.outOfRange(2, lower: 0, upper: 1)))))),
            F.snapshot([F.pid("a"): F.value(0)])
        ]
        for (index, message) in messages.enumerated() {
            let bytes = F.bytes(message)
            #expect(!bytes.isEmpty, "message \(index) encodes")
            for length in 0..<bytes.count {
                #expect(Self.isMalformed(F.decode(Array(bytes.prefix(length)))), "message \(index) prefix \(length)")
            }
        }
    }

    @Test func trailingByteIsRefusedAtItsExactOffset() {
        for golden in F.goldens {
            #expect(F.decode(golden.bytes + [0]) == .failure(.malformed(offset: golden.bytes.count)))
            #expect(F.decode(golden.bytes + [0, 0, 0]) == .failure(.malformed(offset: golden.bytes.count)))
        }
    }

    @Test func emptyPayloadIsMalformedAtZeroAndUnknownTagsAreNamed() {
        #expect(F.decode([]) == .failure(.malformed(offset: 0)))
        for tag in [UInt8(0), 6, 7, 0x80, 0xFF] {
            #expect(F.decode([tag] + F.goldenSnapshot.dropFirst()) == .failure(.unknownTag(tag)))
        }
    }

    @Test func oversizedPayloadIsRefusedBeforeTheTagIsRead() {
        let bytes = [UInt8(0xFF)] + [UInt8](repeating: 0, count: 1_030)
        #expect(F.decode(bytes, frame: F.frameLimits(1_024)) == .failure(.payloadTooLarge(1_031)))
        let atLimit = [UInt8](repeating: 0xFF, count: 1_024)
        #expect(F.decode(atLimit, frame: F.frameLimits(1_024)) == .failure(.unknownTag(0xFF)))
    }

    @Test func sessionMismatchIsReportedPerComponentForEveryKind() {
        let others: [(String, PeerSyncSession)] = [
            ("host id", F.session(hostID: HostID(validated: "x"))),
            ("host generation", F.session(host: 9)),
            ("connection id", F.session(connectionID: ConnectionID(validated: "x"))),
            ("connection generation", F.session(connection: 9))
        ]
        for (name, other) in others {
            let message: [PeerControlMessage] = [
                F.snapshot([:], session: other), F.delta(session: other),
                .resync(PeerResyncWireRequest(session: other, lastApplied: F.seq(1), reason: .unappliable))
            ]
            for item in message {
                #expect(F.decode(F.bytes(item)) == .failure(.sessionMismatch), "\(name)")
            }
        }
    }

    @Test func sessionMismatchComesBeforeLimitsAndBeforeBadEntries() {
        let other = F.session(host: 9)
        let wrong = F.snapshotHead(count: 100_000, session: F.idBytes("h") + F.u64(9) + F.idBytes("c") + F.u64(2))
        #expect(other.hostEpoch.generation != F.session().hostEpoch.generation)
        #expect(F.decode(wrong) == .failure(.sessionMismatch))
        let badSequence = F.snapshotHead(count: 0, sequence: 1 << 53,
                                         session: F.idBytes("h") + F.u64(9) + F.idBytes("c") + F.u64(2))
        #expect(F.decode(badSequence) == .failure(.sessionMismatch))
    }

    @Test func malformedSessionFieldsAreMalformedNotMismatched() {
        let zeroGeneration = F.idBytes("h") + F.u64(0) + F.idBytes("c") + F.u64(2)
        let hugeGeneration = F.idBytes("h") + F.u64(1) + F.idBytes("c") + F.u64(1 << 53)
        let badHost = [UInt8(1), 0x20] + F.u64(1) + F.idBytes("c") + F.u64(2)
        let wrappedGeneration = F.idBytes("h") + F.u64(1) + F.idBytes("c") + F.u64(1 << 53 | 2)
        for session in [zeroGeneration, hugeGeneration, wrappedGeneration, badHost] {
            #expect(Self.isMalformed(F.decode(F.snapshotHead(count: 0, session: session))))
        }
    }

    @Test func countAboveTheLimitIsReportedBeforeTheRemainingBytesCheck() {
        #expect(F.decode(F.snapshotHead(count: 4_097)) == .failure(.tooManyEntries(4_097)))
        #expect(F.decode(F.snapshotHead(count: UInt64(UInt32.max))) == .failure(.tooManyEntries(Int(UInt32.max))))
        #expect(F.decode(F.deltaHead(updates: 257, removals: 0)) == .failure(.tooManyEntries(257)))
        #expect(F.decode(F.deltaHead(updates: UInt64(UInt32.max), removals: UInt64(UInt32.max)))
                == .failure(.tooManyEntries(2 * Int(UInt32.max))))
    }

    @Test func countThatCannotFitTheRemainingBytesIsMalformedAtTheEntryStart() {
        let head = F.snapshotHead(count: 2)
        let start = head.count
        let shortSecond = head + F.entry("a") + [0x01, 0x62, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(F.decode(shortSecond) == .failure(.malformed(offset: start)))
        let removalsHead = F.deltaHead(updates: 0, removals: 4)
        let shortRemovals = removalsHead + F.idBytes("a") + F.idBytes("b") + F.idBytes("c")
        #expect(F.decode(shortRemovals) == .failure(.malformed(offset: removalsHead.count)))
    }

    @Test func entryCountExactlyFittingTheBytesIsAcceptedWhenTheEntriesAreValid() {
        #expect((try? F.decode(F.snapshotHead(count: 2) + F.entry("a") + F.entry("b")).get().tag) == .snapshot)
    }

    @Test func unsortedAndDuplicateEntriesAreNotCanonical() {
        #expect(F.decode(F.snapshotHead(count: 2) + F.entry("b") + F.entry("a")) == .failure(.notCanonical))
        #expect(F.decode(F.snapshotHead(count: 2) + F.entry("a") + F.entry("a")) == .failure(.notCanonical))
        #expect(F.decode(F.snapshotHead(count: 2) + F.entry("a.b") + F.entry("a-b")) == .failure(.notCanonical))
        #expect(F.decode(F.deltaHead(updates: 2, removals: 0) + F.entry("b") + F.entry("a")) == .failure(.notCanonical))
        #expect(F.decode(F.deltaHead(updates: 0, removals: 2) + F.idBytes("b") + F.idBytes("a"))
                == .failure(.notCanonical))
        #expect(F.decode(F.deltaHead(updates: 0, removals: 2) + F.idBytes("a") + F.idBytes("a"))
                == .failure(.notCanonical))
    }

    @Test func updateAndRemovalOfTheSameIdIsNotCanonical() {
        let bytes = F.deltaHead(updates: 1, removals: 1) + F.entry("a") + F.idBytes("a")
        #expect(F.decode(bytes) == .failure(.notCanonical))
    }

    @Test func nonFiniteDoublesAreRefusedInEveryEntryPosition() {
        let bad: [Double] = [.nan, .infinity, -.infinity]
        for number in bad {
            #expect(F.decode(F.snapshotHead(count: 1) + F.entry("a", number)) == .failure(.nonFiniteValue))
            #expect(F.decode(F.deltaHead(updates: 1, removals: 0) + F.entry("a", number)) == .failure(.nonFiniteValue))
            let second = F.snapshotHead(count: 2) + F.entry("a") + F.entry("b", number)
            #expect(F.decode(second) == .failure(.nonFiniteValue))
        }
        let payloadNaN = F.snapshotHead(count: 1) + F.idBytes("a") + F.u64(Double.nan.bitPattern | 1) + [2]
        #expect(F.decode(payloadNaN) == .failure(.nonFiniteValue))
    }

    @Test func nonFiniteValueIsReportedBeforeABadUnitInTheSameEntry() {
        let both = F.snapshotHead(count: 1) + F.idBytes("a") + F.valueBytes(.nan, 0)
        #expect(F.decode(both) == .failure(.nonFiniteValue))
        let unit = F.snapshotHead(count: 1) + F.idBytes("a") + F.valueBytes(0.5, 0)
        #expect(F.decode(unit) == .failure(.malformed(offset: F.snapshotHead(count: 1).count + 2 + 8)))
        #expect(Self.isMalformed(F.decode(F.snapshotHead(count: 1) + F.idBytes("a") + F.valueBytes(0.5, 7))))
    }

    @Test func idsOfTheWrongShapeAreMalformed() {
        let head = F.snapshotHead(count: 1)
        let tail = F.valueBytes(0.5)
        #expect(F.decode(head + [0] + tail) == .failure(.malformed(offset: head.count)))
        let long = [UInt8(129)] + [UInt8](repeating: 0x61, count: 129)
        #expect(F.decode(head + long + tail) == .failure(.malformed(offset: head.count)))
        let longest = [UInt8(128)] + [UInt8](repeating: 0x61, count: 128)
        #expect((try? F.decode(head + longest + tail).get().tag) == .snapshot)
        #expect(F.decode(head + [2, 0xC3, 0xA9] + tail) == .failure(.malformed(offset: head.count)))
        #expect(F.decode(head + [1, 0x20] + tail) == .failure(.malformed(offset: head.count)))
        #expect(F.decode(head + [2, 0xC3, 0x28] + tail) == .failure(.malformed(offset: head.count + 1)))
        #expect(F.decode(head + [1, 0xFF] + tail) == .failure(.malformed(offset: head.count + 1)))
    }

    @Test func sequenceAndRevisionBoundsAreEnforcedOnDecode() {
        let top = UInt64(1 << 53) - 1
        #expect((try? F.decode(F.snapshotHead(count: 0, sequence: top)).get().tag) == .snapshot)
        #expect(Self.isMalformed(F.decode(F.snapshotHead(count: 0, sequence: top + 1))))
        #expect(Self.isMalformed(F.decode(F.snapshotHead(count: 0, sequence: UInt64.max))))
        #expect((try? F.decode(F.snapshotHead(count: 0, sequence: 0)).get().tag) == .snapshot)
        let sessionEnd = 1 + F.sessionBytes.count + 8
        for slot in 0..<5 {
            var bytes = F.snapshotHead(count: 0)
            let start = sessionEnd + slot * 8
            bytes.replaceSubrange(start..<(start + 8), with: F.u64(1 << 53))
            #expect(F.decode(bytes) == .failure(.malformed(offset: start)))
            bytes.replaceSubrange(start..<(start + 8), with: F.u64(top))
            #expect((try? F.decode(bytes).get().tag) == .snapshot)
            bytes.replaceSubrange(start..<(start + 8), with: F.u64(0))
            #expect((try? F.decode(bytes).get().tag) == .snapshot)
        }
    }

    @Test func resyncReasonsAndTheirFieldsAreValidated() {
        var head = [UInt8(3)] + F.sessionBytes + F.u64(4)
        #expect(F.decode(head + [0]) == .failure(.malformed(offset: head.count)))
        #expect(F.decode(head + [5]) == .failure(.malformed(offset: head.count)))
        #expect(F.decode(head + [3]) == .success(F.resync(.unappliable)))
        #expect(F.decode(head + [4]) == .success(F.resync(.snapshotRefused)))
        #expect(F.decode(head + [2] + F.u64(9)) == .success(F.resync(.repeated(F.seq(9)))))
        #expect(Self.isMalformed(F.decode(head + [1] + F.u64(5) + F.u64(1 << 53))))
        head.append(3)
        #expect(F.decode(head + [0]) == .failure(.malformed(offset: head.count)))
    }

    @Test func commandAndResultPayloadsDoNotDependOnTheExpectedSession() {
        let other = F.session(host: 9, connection: 8)
        #expect(F.decode(F.goldenCommand, session: other) == .success(F.goldenCommandMessage))
        #expect(F.decode(F.goldenResult, session: other) == .success(F.goldenResultMessage))
    }

    @Test func decodingTheSameBytesTwiceGivesTheSameOutcomeAndLeavesTheInputUnchanged() {
        let good = F.goldenSnapshot
        let goodCopy = good
        #expect(F.decode(good) == F.decode(good))
        #expect(F.decode(good) == .success(F.goldenSnapshotMessage))
        let bad = Array(good.dropLast())
        let badCopy = bad
        let first = F.decode(bad)
        #expect(first == F.decode(bad))
        #expect(Self.isMalformed(first))
        #expect(good == goodCopy)
        #expect(bad == badCopy)
        #expect(F.decode(good) == .success(F.goldenSnapshotMessage))
    }
}
// swiftlint:enable type_name
