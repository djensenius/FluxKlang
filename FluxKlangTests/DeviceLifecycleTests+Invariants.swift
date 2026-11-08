import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension DeviceLifecycleTests {
    @Test func duplicateObservationMayOmitMeasurement() throws {
        let baseline = try Self.registryTestMeasured()
        let original = try Self.registryTestRecord(1, measured: baseline)
        let registry = try #require(Self.registryTestReduce(.empty, .observed(original)))
        let noInformation = try Self.registryTestRecord(1)
        let changedBaseline = try Self.registryTestRecord(
            1, measured: Self.registryTestMeasured(bufferFrames: 256)
        )

        #expect(registry.applying(.observed(noInformation))
            == .accepted(registry, effect: nil))
        #expect(registry.applying(.observed(changedBaseline))
            == .refused(.conflictingObservation(original.identityKey)))
    }

    @Test func missingBaselineStaysNilOnRepeat() throws {
        let record = try Self.registryTestRecord(1)
        let registered = try #require(Self.registryTestReduce(.empty, .observed(record)))
        let lost = try #require(Self.registryTestReduce(
            registered, .disappeared(record.identityKey)
        ))
        let returning = try #require(Self.registryTestReduce(
            lost, .returned(record.identityKey)
        ))
        let measurement = try Self.registryTestMeasured()
        let firstResult = returning.applying(
            .capabilitiesMeasured(record.identityKey, measurement)
        )
        guard case .accepted(let first, let firstEffect) = firstResult else {
            Issue.record("first returned measurement was refused")
            return
        }
        let firstRecord = try #require(first.record(for: record.identityKey))
        #expect(firstRecord.lifecycle == .muted(.noMeasuredBaseline))
        #expect(firstRecord.measuredCapabilities == nil)

        let secondResult = first.applying(
            .capabilitiesMeasured(record.identityKey, measurement)
        )
        guard case .accepted(let second, let secondEffect) = secondResult else {
            Issue.record("repeated returned measurement was refused")
            return
        }
        #expect(firstEffect == .lifecycleChanged(
            record.id, from: .revalidating, to: .muted(.noMeasuredBaseline)
        ))
        #expect(secondEffect == nil)
        let secondRecord = try #require(second.record(for: record.identityKey))
        #expect(secondRecord.lifecycle == .muted(.noMeasuredBaseline))
        #expect(secondRecord.measuredCapabilities == nil)
    }

    @Test func presentMismatchMutesImmediately() throws {
        let baseline = try Self.registryTestMeasured()
        let record = try Self.registryTestRecord(1, measured: baseline)
        let registry = try #require(Self.registryTestReduce(.empty, .observed(record)))
        let mismatch = try Self.registryTestMeasured(bufferFrames: 256)
        let result = registry.applying(
            .capabilitiesMeasured(record.identityKey, mismatch)
        )
        guard case .accepted(let muted, let effect) = result else {
            Issue.record("present mismatch measurement was refused")
            return
        }
        #expect(effect == .lifecycleChanged(
            record.id, from: .present, to: .muted(.capabilityMismatch(.bufferFrames))
        ))
        let mutedRecord = try #require(muted.record(for: record.identityKey))
        #expect(mutedRecord.lifecycle == .muted(.capabilityMismatch(.bufferFrames)))
        #expect(!muted.allowsEngineAcquisition)
    }

    @Test func registryEqualityDistinguishesLifecycle() throws {
        let record = try Self.registryTestRecord(20)
        let present = try Self.registryForEquality(record)
        let lost = try #require(Self.registryTestReduce(
            present, .disappeared(record.identityKey)
        ))

        #expect(present != lost)
    }

    @Test func registryEqualityPinsRecordFields() throws {
        let id = try DeviceID("dev.registry-equality")
        let uid = "uid.registry-equality"
        let baseline = try Self.registryTestMeasured()
        let original = try Self.registryTestRecord(id: id, uid: uid, measured: baseline)
        let originalRegistry = try Self.registryForEquality(original)
        let changedBaseline = try Self.registryTestRecord(
            id: id, uid: uid, measured: Self.registryTestMeasured(bufferFrames: 256)
        )
        let baselineRegistry = try Self.registryForEquality(changedBaseline)
        let modelEvidence = try Self.registryTestRecord(
            id: id, uid: uid, evidence: [.deviceUID, .modelUID], measured: baseline
        )
        let modelRegistry = try Self.registryForEquality(modelEvidence)
        let otherID = try DeviceID("dev.registry-equality.other")
        let changedID = try Self.registryTestRecord(
            id: otherID, uid: uid, measured: baseline
        )
        let deviceIDRegistry = try Self.registryForEquality(changedID)

        #expect(originalRegistry != baselineRegistry)
        #expect(originalRegistry != modelRegistry)
        #expect(originalRegistry != deviceIDRegistry)
    }

    @Test func registryEqualityAndHashAreOrderStable() throws {
        var forward = DeviceRegistry.empty
        for index in 0..<64 {
            let record = try Self.registryTestRecord(100 + index)
            forward = try #require(Self.registryTestReduce(forward, .observed(record)))
        }
        var reverse = DeviceRegistry.empty
        for index in (0..<64).reversed() {
            let record = try Self.registryTestRecord(100 + index)
            reverse = try #require(Self.registryTestReduce(reverse, .observed(record)))
        }

        #expect(forward == reverse)
        var forwardHasher = Hasher()
        forwardHasher.combine(forward)
        let forwardHash = forwardHasher.finalize()
        var reverseHasher = Hasher()
        reverseHasher.combine(reverse)
        let reverseHash = reverseHasher.finalize()
        #expect(forwardHash == reverseHash)
    }

    private static func registryForEquality(_ record: DeviceRecord) throws -> DeviceRegistry {
        try #require(Self.registryTestReduce(.empty, .observed(record)))
    }
}

private struct DeviceIdentityBytesSplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

extension DeviceLifecycleTests {
    private static let identityBytesEAcute = "\u{E9}"
    private static let identityBytesEAndAcute = "e\u{301}"
    private static let identityBytesAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789.-_")
    private static let identityBytesSeeds: [UInt64] = [1, 0xD3A2, 0x65]
    private static let identityBytesShapes: [Set<IdentityEvidence>] = [[.deviceUID], [.endpointUID, .deviceUID]]

    private static func identityBytesKey(
        _ uid: String, _ evidence: Set<IdentityEvidence> = [.deviceUID]
    ) throws -> DeviceIdentityKey {
        let identity = try DeviceIdentity(DeviceIdentityFields(uid: uid, evidence: evidence))
        return try DeviceIdentityKey.make(from: identity)
    }

    private static func identityBytesRecord(_ id: String, _ uid: String) throws -> DeviceRecord {
        try registryTestRecord(id: DeviceID(id), uid: uid)
    }

    /// Copy of main (DeviceRecord.swift `<` before DEV2): String order on `uid`, then the evidence join.
    private static func identityBytesOldLess(_ lhs: DeviceIdentityKey, _ rhs: DeviceIdentityKey) -> Bool {
        if lhs.uid != rhs.uid { return lhs.uid < rhs.uid }
        return lhs.evidence.map(\.rawValue).joined(separator: ",")
            < rhs.evidence.map(\.rawValue).joined(separator: ",")
    }

    private static func identityBytesOldEqual(_ lhs: DeviceIdentityKey, _ rhs: DeviceIdentityKey) -> Bool {
        let sameUID = lhs.uid == rhs.uid
        let sameEvidence = lhs.evidence == rhs.evidence
        return sameUID && sameEvidence
    }

    private static func identityBytesASCII(
        _ generator: inout DeviceIdentityBytesSplitMix, length: Int
    ) -> String {
        var text = ""
        let count = UInt64(identityBytesAlphabet.count)
        for _ in 0..<length {
            let index = Int(generator.next() % count)
            text.append(identityBytesAlphabet[index])
        }
        return text
    }

    private static func identityBytesJoined(
        _ generator: inout DeviceIdentityBytesSplitMix, _ pieces: [String]
    ) -> String {
        var text = ""
        let count = UInt64(pieces.count)
        for _ in 0..<3 {
            let index = Int(generator.next() % count)
            text.append(pieces[index])
        }
        return text
    }

    @Test func deviceIdentityBytesKeepCanonicallyEquivalentUIDsApart() throws {
        let precomposed = try Self.identityBytesKey(Self.identityBytesEAcute)
        let decomposed = try Self.identityBytesKey(Self.identityBytesEAndAcute)
        let sameCharacters = precomposed.uid == decomposed.uid
        #expect(sameCharacters)
        #expect(precomposed != decomposed)
        #expect(Set([precomposed, decomposed]).count == 2)

        let ringPrecomposed = try Self.identityBytesKey("\u{C5}")
        let ringDecomposed = try Self.identityBytesKey("A\u{30A}")
        let angstrom = try Self.identityBytesKey("\u{212B}")
        #expect(ringPrecomposed != ringDecomposed)
        #expect(ringPrecomposed != angstrom)
        #expect(ringDecomposed != angstrom)
        #expect(Set([ringPrecomposed, ringDecomposed, angstrom]).count == 3)
    }

    @Test func deviceIdentityBytesRegistryRegistersBothSpellingsAsTwoUnits() throws {
        let first = try Self.identityBytesRecord("dev.a", Self.identityBytesEAcute)
        let second = try Self.identityBytesRecord("dev.b", Self.identityBytesEAndAcute)
        let registry = try #require(Self.registryTestReduce(.empty, .observed(first)))
        let result = registry.applying(.observed(second))
        guard case .accepted(let both, let effect) = result else {
            Issue.record("the second spelling was refused: \(result)")
            return
        }
        #expect(effect == .registered(second.id))
        #expect(both.records.count == 2)
        #expect(both.record(for: first.identityKey) == first)
        #expect(both.record(for: second.identityKey) == second)
    }

    @Test func deviceIdentityBytesSameIDDifferentSpellingIsADuplicateDeviceID() throws {
        let first = try Self.identityBytesRecord("dev.a", Self.identityBytesEAcute)
        let second = try Self.identityBytesRecord("dev.a", Self.identityBytesEAndAcute)
        let registry = try #require(Self.registryTestReduce(.empty, .observed(first)))
        #expect(registry.applying(.observed(second)) == .refused(.duplicateDeviceID(first.id)))
    }

    @Test func deviceIdentityBytesDisappearedOneSpellingLeavesTheOther() throws {
        let first = try Self.identityBytesRecord("dev.a", Self.identityBytesEAcute)
        let second = try Self.identityBytesRecord("dev.b", Self.identityBytesEAndAcute)
        var registry = try #require(Self.registryTestReduce(.empty, .observed(first)))
        registry = try #require(Self.registryTestReduce(registry, .observed(second)))
        let afterLoss = try #require(Self.registryTestReduce(registry, .disappeared(second.identityKey)))
        let survivor = try #require(afterLoss.record(for: first.identityKey))
        let lost = try #require(afterLoss.record(for: second.identityKey))
        #expect(survivor.lifecycle == .present)
        #expect(lost.lifecycle == .lostMuted)
        #expect(survivor.id == first.id)
        #expect(lost.id == second.id)
    }

    @Test func deviceIdentityBytesOrderIsByteOrderForNonASCII() throws {
        let decomposed = try Self.identityBytesKey(Self.identityBytesEAndAcute)
        let precomposed = try Self.identityBytesKey(Self.identityBytesEAcute)
        let decomposedFirst = decomposed < precomposed
        let precomposedFirst = precomposed < decomposed
        #expect(decomposedFirst)
        #expect(!precomposedFirst)
        #expect([precomposed, decomposed].sorted() == [decomposed, precomposed])

        let longDecomposed = try Self.identityBytesKey("e\u{301}x")
        let grave = try Self.identityBytesKey("\u{E8}")
        let longFirst = longDecomposed < grave
        let graveFirst = grave < longDecomposed
        #expect(longFirst)
        #expect(!graveFirst)
    }

    @Test func deviceIdentityBytesSameUIDEvidenceBreaksTheTie() throws {
        let device = try Self.identityBytesKey("uid.tie", [.deviceUID])
        let endpoint = try Self.identityBytesKey("uid.tie", [.endpointUID])
        let deviceFirst = device < endpoint
        let endpointFirst = endpoint < device
        #expect(deviceFirst)
        #expect(!endpointFirst)
        #expect(device != endpoint)
    }

    @Test func deviceIdentityBytesASCIIOrderAndEqualityMatchTheOldCopy() throws {
        let lengths = [1, 2, 3, 5, 8, 40, 1_024]
        var cases = 0
        for seed in Self.identityBytesSeeds {
            var generator = DeviceIdentityBytesSplitMix(state: seed)
            var matrix: [DeviceIdentityKey] = []
            for index in 0..<400 {
                let uid = Self.identityBytesASCII(&generator, length: lengths[index % lengths.count])
                let shape = Self.identityBytesShapes[index % 2]
                let key = try Self.identityBytesKey(uid, shape)
                #expect(key.uid == uid)
                if index < 40 { matrix.append(key) }
            }
            for index in 0..<6 {
                let uid = Self.identityBytesASCII(&generator, length: lengths[index])
                for shape in Self.identityBytesShapes { matrix.append(try Self.identityBytesKey(uid, shape)) }
            }
            for lhs in matrix {
                for rhs in matrix {
                    let newEqual = lhs == rhs
                    let newLess = lhs < rhs
                    #expect(newEqual == Self.identityBytesOldEqual(lhs, rhs))
                    #expect(newLess == Self.identityBytesOldLess(lhs, rhs))
                    if newEqual { #expect(lhs.hashValue == rhs.hashValue) }
                    cases += 1
                }
            }
        }
        let expectedCases = 8_112
        #expect(cases == expectedCases)
    }

    @Test func deviceIdentityBytesNonASCIIPiecesFollowByteEqualityAndOrder() throws {
        let pieces = [
            "a", "e", Self.identityBytesEAcute, Self.identityBytesEAndAcute, "\u{301}", "\u{C5}", "A\u{30A}",
            "\u{212B}", "\u{1F3A7}", "Z"
        ]
        for seed in Self.identityBytesSeeds {
            var generator = DeviceIdentityBytesSplitMix(state: seed)
            var keys: [DeviceIdentityKey] = []
            for _ in 0..<60 {
                let uid = Self.identityBytesJoined(&generator, pieces)
                keys.append(try Self.identityBytesKey(uid))
            }
            for lhs in keys {
                for rhs in keys {
                    let lhsBytes = Array(lhs.uid.utf8)
                    let rhsBytes = Array(rhs.uid.utf8)
                    let sameBytes = lhsBytes == rhsBytes
                    let bytesBefore = lhsBytes.lexicographicallyPrecedes(rhsBytes)
                    let keysEqual = lhs == rhs
                    let keyBefore = lhs < rhs
                    #expect(keysEqual == sameBytes)
                    #expect(keyBefore == bytesBefore)
                }
            }
            let distinctBytes = Set(keys.map { Array($0.uid.utf8) })
            let unique = Array(Set(keys))
            #expect(unique.count == distinctBytes.count)
            let ordered = unique.sorted()
            for index in 1..<ordered.count {
                let strictlyAscending = ordered[index - 1] < ordered[index]
                #expect(strictlyAscending)
            }
        }
    }

    @Test func deviceIdentityBytesRegistryRecordsAreSortedByUIDBytes() throws {
        let pieces = ["a", "e", Self.identityBytesEAcute, Self.identityBytesEAndAcute, "\u{301}", "\u{C5}", "A\u{30A}"]
        var generator = DeviceIdentityBytesSplitMix(state: 0x65)
        var seen = Set<[UInt8]>()
        var uids: [String] = []
        for _ in 0..<60 {
            let uid = Self.identityBytesJoined(&generator, pieces)
            if seen.insert(Array(uid.utf8)).inserted { uids.append(uid) }
        }
        var registry = DeviceRegistry.empty
        for (index, uid) in uids.enumerated() {
            let record = try Self.identityBytesRecord("dev.bytes.\(index)", uid)
            registry = try #require(Self.registryTestReduce(registry, .observed(record)))
        }
        let expected = uids.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        #expect(registry.records.count == uids.count)
        #expect(registry.records.map(\.identityKey.uid) == expected)
    }

    @Test func deviceIdentityBytesUIDLimitIs1024Bytes() throws {
        let asciiLimit = String(repeating: "u", count: 1_024)
        let multiByteLimit = String(repeating: Self.identityBytesEAcute, count: 512)
        let belowLimit = try Self.identityBytesKey(String(repeating: "u", count: 1_023))
        #expect(belowLimit.uid.utf8.count == 1_023)
        let acceptedLimits = [asciiLimit, multiByteLimit]
        for uid in acceptedLimits {
            let key = try Self.identityBytesKey(uid)
            #expect(key.uid.utf8.count == 1_024)
        }
        let refusedLimits = [
            String(repeating: "u", count: 1_025), String(repeating: Self.identityBytesEAcute, count: 513), "", "   "
        ]
        for uid in refusedLimits {
            #expect(throws: DeviceRegistryRefusal.missingUIDEvidence) { try Self.identityBytesRecord("dev.a", uid) }
        }
        let prefix = String(repeating: "u", count: 1_023)
        let low = try Self.identityBytesKey(prefix + "a")
        let high = try Self.identityBytesKey(prefix + "b")
        let lowFirst = low < high
        let highFirst = high < low
        #expect(low != high)
        #expect(lowFirst)
        #expect(!highFirst)
    }

    @Test func deviceIdentityBytesMultiEvidenceTieBreakIsHandOrdered() throws {
        let both = try Self.identityBytesKey("uid.tie", [.endpointUID, .deviceUID])
        let deviceOnly = try Self.identityBytesKey("uid.tie", [.deviceUID])
        let endpointOnly = try Self.identityBytesKey("uid.tie", [.endpointUID])
        let expected = [deviceOnly, both, endpointOnly]
        #expect([endpointOnly, both, deviceOnly].sorted() == expected)
        #expect([both, endpointOnly, deviceOnly].sorted() == expected)
        let bothFirst = both < endpointOnly
        let endpointFirst = endpointOnly < both
        #expect(bothFirst)
        #expect(!endpointFirst)
        let deviceFirst = deviceOnly < both
        let bothBeforeDevice = both < deviceOnly
        #expect(deviceFirst)
        #expect(!bothBeforeDevice)
    }
}
