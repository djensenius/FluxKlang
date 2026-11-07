//
//  PeerEndpointPolicyTests+Order.swift
//  FluxKlangTests
//
//  Refusal order of `decide` (both-defects fixtures in both input orders), the point-of-use policy
//  re-validation and the availability mapping (#93, slice P4).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerEndpointPolicyTests {
    private static func rules(
        allowed: Set<PeerAddressClass> = Set(PeerAddressClass.allCases),
        denied: [PeerAddressMask] = [],
        localLink: Bool = false,
        manual: Bool = true
    ) -> PeerEndpointPolicy.Rules {
        PeerEndpointPolicy.Rules(
            allowedClasses: allowed,
            denied: denied,
            requireLocalLink: localLink,
            manualEntryAllowed: manual
        )
    }

    /// A mask list of `count` entries with the matching mask at `matchIndex` and non-matching filler elsewhere.
    private static func maskList(count: Int, matchIndex: Int, match: PeerAddressMask) throws -> [PeerAddressMask] {
        let filler = try mask(v4Bytes(1, 0, 0, 0), 8)
        return (0..<count).map { $0 == matchIndex ? match : filler }
    }

    @Test func anOverlongDeniedListIsAnInvalidPolicyBeforeAnyMaskIsConsulted() throws {
        let match = try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8)
        let target = try Self.address(Self.v4Bytes(10, 1, 1, 1))
        for (count, index) in [(65, 0), (65, 64), (100, 50)] {
            let denied = try Self.maskList(count: count, matchIndex: index, match: match)
            let decision = PeerEndpointPolicy.evaluate(target, origin: .manual, rules: Self.rules(denied: denied))
            #expect(decision == .refused(.invalidPolicy(deniedCount: count)), "\(count) \(index)")
        }
    }

    @Test func theRevalidationAcceptsExactlySixtyFourDeniedMasksAtThePointOfUse() throws {
        let match = try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8)
        let target = try Self.address(Self.v4Bytes(10, 1, 1, 1))
        let atLimit = try Self.maskList(count: 64, matchIndex: 63, match: match)
        let decision = PeerEndpointPolicy.evaluate(target, origin: .manual, rules: Self.rules(denied: atLimit))
        #expect(decision == .refused(.denied(maskIndex: 63)))
        let clean = PeerEndpointPolicy.evaluate(target, origin: .manual, rules: Self.rules(denied: []))
        #expect(clean == .allowed)
    }

    @Test func aDeniedMaskBeatsManualEntryDisabledInBothMaskListOrders() throws {
        let match = try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8)
        let target = try Self.address(Self.v4Bytes(10, 1, 1, 1))
        for index in [0, 2] {
            let denied = try Self.maskList(count: 3, matchIndex: index, match: match)
            let policy = try Self.policy(denied: denied, manual: false)
            #expect(policy.decide(target, origin: .manual) == .refused(.denied(maskIndex: index)))
            #expect(policy.decide(target, origin: .discovered) == .refused(.denied(maskIndex: index)))
        }
    }

    @Test func manualEntryDisabledBeatsClassNotAllowedForManualOriginsOnly() throws {
        let target = try Self.address(Self.v4Bytes(8, 8, 8, 8))
        let policy = try Self.policy(allowed: [.privateRange], manual: false)
        #expect(policy.decide(target, origin: .manual) == .refused(.manualEntryDisabled))
        #expect(policy.decide(target, origin: .discovered) == .refused(.classNotAllowed(.publicRange)))
        let otherClass = try Self.address(Self.v4Bytes(127, 0, 0, 1))
        #expect(policy.decide(otherClass, origin: .manual) == .refused(.manualEntryDisabled))
        #expect(policy.decide(otherClass, origin: .discovered) == .refused(.classNotAllowed(.loopback)))
    }

    @Test func classNotAllowedBeatsNotLocalLinkAndNotLocalLinkNeedsAnAllowedClass() throws {
        let target = try Self.address(Self.v4Bytes(8, 8, 8, 8))
        let both = try Self.policy(allowed: [.linkLocal], localLink: true)
        #expect(both.decide(target, origin: .discovered) == .refused(.classNotAllowed(.publicRange)))
        #expect(both.decide(target, origin: .manual) == .refused(.classNotAllowed(.publicRange)))
        let onlyLocal = try Self.policy(allowed: [.linkLocal, .publicRange], localLink: true)
        #expect(onlyLocal.decide(target, origin: .discovered) == .refused(.notLocalLink))
        #expect(onlyLocal.decide(target, origin: .manual) == .refused(.notLocalLink))
    }

    @Test func everyDefectAtOnceReportsTheInvalidPolicyThenTheDeniedMaskInOrder() throws {
        let match = try Self.mask(Self.v4Bytes(8, 8, 8, 8), 32)
        let target = try Self.address(Self.v4Bytes(8, 8, 8, 8))
        let wide = try Self.maskList(count: 65, matchIndex: 1, match: match)
        let invalid = PeerEndpointPolicy.evaluate(
            target, origin: .manual, rules: Self.rules(allowed: [], denied: wide, localLink: true, manual: false)
        )
        #expect(invalid == .refused(.invalidPolicy(deniedCount: 65)))
        let valid = try Self.policy(allowed: [], denied: [match], localLink: true, manual: false)
        #expect(valid.decide(target, origin: .manual) == .refused(.denied(maskIndex: 0)))
        let noDenial = try Self.policy(allowed: [], localLink: true, manual: false)
        #expect(noDenial.decide(target, origin: .manual) == .refused(.manualEntryDisabled))
        let manualOk = try Self.policy(allowed: [], localLink: true, manual: true)
        #expect(manualOk.decide(target, origin: .manual) == .refused(.classNotAllowed(.publicRange)))
    }

    @Test func theAvailabilityMappingSendsDeniedToDeniedAndEveryOtherRefusalToIneligible() throws {
        #expect(PeerEndpointDecision.allowed.mapsTo == .available)
        #expect(PeerEndpointDecision.refused(.denied(maskIndex: 3)).mapsTo == .denied)
        let others: [PeerEndpointRefusal] = [
            .badLength(count: 7), .badPort, .zoneNotAllowed, .badZone, .badPrefix(bits: 40, maximum: 32),
            .tooManyDenied(limit: 64), .invalidPolicy(deniedCount: 65), .manualEntryDisabled,
            .classNotAllowed(.multicast), .notLocalLink
        ]
        for refusal in others { #expect(PeerEndpointDecision.refused(refusal).mapsTo == .ineligible, "\(refusal)") }
        let mask = try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8)
        let policy = try Self.policy(allowed: [.privateRange], denied: [mask], manual: false)
        let denied = try Self.address(Self.v4Bytes(10, 0, 0, 1))
        let other = try Self.address(Self.v4Bytes(192, 168, 0, 1))
        #expect(policy.decide(denied, origin: .discovered).mapsTo == .denied)
        #expect(policy.decide(other, origin: .manual).mapsTo == .ineligible)
        #expect(policy.decide(other, origin: .discovered).mapsTo == .available)
    }
}
