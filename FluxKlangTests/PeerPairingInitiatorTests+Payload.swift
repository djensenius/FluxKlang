import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerPairingInitiatorTests {
    /// 40 labels with their expected verdict, covering each clause of the label rule.
    static let labelTable: [(label: String, valid: Bool)] = [
        ("a", true), ("Remote C", true), ("iPad (Stage)", true), ("R\u{E9}gie", true), ("e\u{301}", true),
        ("\u{65E5}\u{672C}\u{8A9E}", true), ("\u{1F39B}\u{FE0F} Rack", true), ("Name-with_punct.", true),
        (String(repeating: "x", count: 64), true), (String(repeating: "\u{20AC}", count: 21) + "a", true),
        ("1", true), ("a\u{FE00}", true), ("a b", true),
        ("", false), (" ", false), ("  a", false), ("a  ", false), ("\u{A0}a", false), ("a\u{A0}", false),
        ("\n", false), ("a\nb", false), ("a\u{0}b", false), ("a\tb", false), ("\u{200B}a", false),
        ("a\u{200B}", false), ("a\u{200D}b", false), ("a\u{202E}b", false), ("a\u{2066}b", false),
        ("\u{301}a", false), ("\u{FE0F}", false), ("a\u{2028}b", false), ("a\u{2029}b", false),
        ("a\u{E000}b", false), ("a\u{378}b", false), ("\u{3164}", false), ("a\u{115F}b", false),
        ("a\u{34F}b", false), ("a\u{600}b", false), (String(repeating: "x", count: 65), false),
        (String(repeating: "\u{20AC}", count: 22), false)
    ]

    private func storeAcceptsLabel(_ label: String) throws -> Bool {
        var store = PeerTrustStore()
        let grants = try PeerGrantSet(role: .observer, commands: [], reads: [.statusRead])
        do {
            _ = try store.pair(Self.identity(7), label: label, grants: grants, protocolFloor: 1)
            return true
        } catch {
            #expect(error == .invalidLabel, "only the label may refuse here")
            return false
        }
    }

    @Test("The label rule agrees with the trust store's own verdict on forty labels")
    func labelRuleAgreesWithTheTrustStoreOnFortyLabels() throws {
        #expect(Self.labelTable.count == 40)
        #expect(Self.labelTable.filter(\.valid).count == 13)
        for entry in Self.labelTable {
            let scalars = entry.label.unicodeScalars.map(\.value)
            #expect(try storeAcceptsLabel(entry.label) == entry.valid, "store: \(scalars)")
            #expect(PeerPairingLabelRule.isValid(entry.label) == entry.valid, "rule: \(scalars)")
        }
        #expect(PeerPairingLabelRule.utf8Bounds == PeerTrustStore.labelUTF8Bounds)
    }

    @Test("Starting an attempt and making a payload both follow the label rule")
    func labelRuleDecidesStartAttemptAndPayloadMakeAlike() throws {
        for entry in Self.labelTable {
            var initiator = PeerPairingInitiator()
            let started = refusal(of: .start(spec(label: entry.label), Self.nonce(1)), on: &initiator, at: start)
            #expect(started == (entry.valid ? nil : .invalidLabel), "start \(entry.label.unicodeScalars.map(\.value))")
            let made = try? PeerPairingPayload.make(hostFingerprint: host, hostLabel: entry.label)
            #expect((made != nil) == entry.valid, "payload \(entry.label.unicodeScalars.map(\.value))")
        }
        #expect(throws: PeerInitiatorError.invalidLabel) {
            try PeerPairingPayload.make(hostFingerprint: host, hostLabel: String(repeating: "x", count: 65))
        }
    }

    @Test("The payload shows all 64 digits of the fingerprint in eight lowercase groups of eight")
    func payloadGroupsAKnownFingerprintIntoEightBlocksOfEightHexDigits() throws {
        let payload = try PeerPairingPayload.make(hostFingerprint: Self.identity(0), hostLabel: "Main Rig")
        #expect(payload.fingerprintGroups == ["00010203", "04050607", "08090a0b", "0c0d0e0f", "10111213",
                                              "14151617", "18191a1b", "1c1d1e1f"])
        #expect(payload.fingerprintDisplay == "00010203 04050607 08090a0b 0c0d0e0f 10111213 14151617 18191a1b 1c1d1e1f")
        #expect(PeerPairingPayload.groupCount == 8 && PeerPairingPayload.groupWidth == 8)
        #expect(payload.hostLabel == "Main Rig" && payload.hostFingerprint == Self.identity(0))
        let letters = try PeerPairingPayload.make(hostFingerprint: Self.identity(0xA0), hostLabel: "X")
        #expect(letters.fingerprintGroups.first == "a0a1a2a3" && letters.fingerprintGroups.last == "bcbdbebf")
    }

    @Test("The displayed digits are the whole fingerprint, not the six-digit code or the redacted description")
    func payloadDisplayIsTheFullFingerprintAndNotTheShortForm() throws {
        let payload = try PeerPairingPayload.make(hostFingerprint: host, hostLabel: "Main Rig")
        let digits = payload.fingerprintGroups.joined()
        #expect(digits == PeerTrustDigest.hex(host.bytes) && digits.count == 64)
        #expect(payload.fingerprintDisplay.count == 71)
        #expect(!String(describing: host).contains(digits.prefix(16)))
    }

    @Test("Labels that differ only in canonical equivalence are different values and different set members")
    func labelsCanonicallyEquivalentButByteDifferentAreNotEqualInPayloadSpecAndInitiator() throws {
        let precomposed = "\u{E9}"
        let decomposed = "e\u{301}"
        #expect(precomposed == decomposed && !precomposed.utf8.elementsEqual(decomposed.utf8))
        #expect(PeerPairingLabelRule.isValid(precomposed) && PeerPairingLabelRule.isValid(decomposed))
        let first = try PeerPairingPayload.make(hostFingerprint: host, hostLabel: precomposed)
        let second = try PeerPairingPayload.make(hostFingerprint: host, hostLabel: decomposed)
        #expect(first != second && Set([first, second]).count == 2)
        #expect(first == (try PeerPairingPayload.make(hostFingerprint: host, hostLabel: "\u{E9}")))
        let specs = [spec(label: precomposed), spec(label: decomposed)]
        #expect(specs[0] != specs[1] && Set(specs).count == 2 && specs[0] == spec(label: "\u{E9}"))
        let initiators = try [precomposed, decomposed].map { label in
            try PeerPairingInitiator.begin(spec(label: label), nonce: Self.nonce(1), now: start).0
        }
        #expect(initiators[0] != initiators[1] && Set(initiators).count == 2)
    }

    @Test("A payload stores only the fingerprint and the label")
    func payloadStoresOnlyTheFingerprintAndTheLabel() throws {
        let payload = try PeerPairingPayload.make(hostFingerprint: host, hostLabel: "Main Rig")
        #expect(Mirror(reflecting: payload).children.compactMap(\.label) == ["hostFingerprint", "hostLabel"])
        let other = try PeerPairingPayload.make(hostFingerprint: host, hostLabel: "Other")
        #expect(payload != other)
        #expect(payload == (try PeerPairingPayload.make(hostFingerprint: host, hostLabel: "Main Rig")))
    }

    @Test("A transport identity matches only when all 32 bytes are equal")
    func payloadMatchesTheNamedHostAndNoOtherIdentity() throws {
        let payload = try PeerPairingPayload.make(hostFingerprint: host, hostLabel: "Main Rig")
        #expect(payload.matches(host) && payload.matches(Self.identity(100)))
        #expect(!payload.matches(own) && !payload.matches(Self.identity(101)))
    }

    @Test("A one-bit difference in any of the 32 bytes is not a match, including byte 0 and byte 31")
    func payloadMatchesRejectsEveryOneBitDifferenceInEveryByte() throws {
        let payload = try PeerPairingPayload.make(hostFingerprint: host, hostLabel: "Main Rig")
        var flips = 0
        for index in 0..<32 {
            for bit in 0..<8 {
                var bytes = host.bytes
                bytes[index] ^= UInt8(1) << UInt8(bit)
                let flipped = try #require(PeerIdentityFingerprint(bytes))
                #expect(!payload.matches(flipped), "byte \(index) bit \(bit)")
                flips += 1
            }
        }
        #expect(flips == 256)
    }
}
