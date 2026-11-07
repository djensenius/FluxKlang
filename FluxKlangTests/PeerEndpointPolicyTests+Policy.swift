//
//  PeerEndpointPolicyTests+Policy.swift
//  FluxKlangTests
//
//  Masks, the policy limits and the allow/deny rules of `decide` (#93, slice P4).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerEndpointPolicyTests {
    @Test func aMaskNeedsFourOrSixteenOctetsAndRefusesOtherLengthsWithTheCount() {
        for count in [0, 3, 5, 15, 17] {
            #expect(throws: PeerEndpointRefusal.badLength(count: count)) {
                try Self.mask(Array(repeating: 0, count: count), 0)
            }
        }
    }

    @Test func aMaskPrefixIsZeroToThirtyTwoForIPv4AndZeroTo128ForIPv6() throws {
        for bits in [0, 1, 31, 32] { #expect(try Self.mask(Self.v4Bytes(10, 0, 0, 0), bits).prefixBits == bits) }
        for bits in [0, 1, 127, 128] { #expect(try Self.mask(Self.v6Bytes([0x20]), bits).prefixBits == bits) }
        for bits in [-1, 33, 129, Int.max, Int.min] {
            #expect(throws: PeerEndpointRefusal.badPrefix(bits: bits, maximum: 32)) {
                try Self.mask(Self.v4Bytes(10, 0, 0, 0), bits)
            }
        }
        for bits in [-1, 129, 1_000] {
            #expect(throws: PeerEndpointRefusal.badPrefix(bits: bits, maximum: 128)) {
                try Self.mask(Self.v6Bytes([0x20]), bits)
            }
        }
        #expect(throws: PeerEndpointRefusal.badPrefix(bits: 33, maximum: 32)) {
            try Self.mask(Self.v4Bytes(10, 0, 0, 0), 33)
        }
        #expect(throws: PeerEndpointRefusal.badPrefix(bits: 129, maximum: 128)) {
            try Self.mask(Self.v6Bytes([0x20]), 129)
        }
        #expect(throws: PeerEndpointRefusal.badLength(count: 5)) { try Self.mask([1, 2, 3, 4, 5], 999) }
    }

    @Test func aMaskZeroesTheHostBitsSoEqualNetworksAreEqualValues() throws {
        #expect(try Self.mask(Self.v4Bytes(10, 1, 2, 3), 8) == (try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8)))
        #expect(try Self.mask(Self.v4Bytes(10, 1, 2, 3), 8).octets == [10, 0, 0, 0])
        #expect(try Self.mask(Self.v4Bytes(172, 31, 9, 9), 12).octets == [172, 16, 0, 0])
        #expect(try Self.mask(Self.v4Bytes(172, 31, 9, 9), 15).octets == [172, 30, 0, 0])
        #expect(try Self.mask(Self.v4Bytes(255, 255, 255, 255), 0).octets == [0, 0, 0, 0])
        #expect(try Self.mask(Self.v4Bytes(255, 255, 255, 255), 32).octets == [255, 255, 255, 255])
        let six = try Self.mask(Array(repeating: 0xFF, count: 16), 65)
        #expect(six.octets == Array(repeating: UInt8(0xFF), count: 8) + [0x80] + Array(repeating: 0, count: 7))
        #expect(try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8) != (try Self.mask(Self.v4Bytes(10, 0, 0, 0), 9)))
    }

    @Test func aPartialByteMaskCoversExactlyItsBlockAtNAndNPlusOne() throws {
        let block = try Self.mask(Self.v4Bytes(172, 16, 0, 0), 12)
        let inside = [Self.v4Bytes(172, 16, 0, 0), Self.v4Bytes(172, 20, 3, 4), Self.v4Bytes(172, 31, 255, 255)]
        let outside = [Self.v4Bytes(172, 15, 255, 255), Self.v4Bytes(172, 32, 0, 0), Self.v4Bytes(171, 16, 0, 0)]
        for bytes in inside { #expect(block.matches(try Self.address(bytes)), "\(bytes)") }
        for bytes in outside { #expect(!block.matches(try Self.address(bytes)), "\(bytes)") }
        let exact = try Self.mask(Self.v4Bytes(8, 8, 8, 8), 32)
        #expect(exact.matches(try Self.address(Self.v4Bytes(8, 8, 8, 8))))
        #expect(!exact.matches(try Self.address(Self.v4Bytes(8, 8, 8, 9))))
        #expect(!exact.matches(try Self.address(Self.v4Bytes(8, 8, 8, 7))))
        let six = try Self.mask(Self.v6Bytes([0x20, 0x01, 0x0D, 0xB8]), 33)
        #expect(six.matches(try Self.address(Self.v6Bytes([0x20, 0x01, 0x0D, 0xB8, 0x7F]))))
        #expect(!six.matches(try Self.address(Self.v6Bytes([0x20, 0x01, 0x0D, 0xB8, 0x80]))))
        #expect(!six.matches(try Self.address(Self.v6Bytes([0x20, 0x01, 0x0D, 0xB7, 0x7F]))))
        let full = try Self.mask(Self.v6Bytes([], tail: [1]), 128)
        #expect(full.matches(try Self.address(Self.v6Bytes([], tail: [1]))))
        #expect(!full.matches(try Self.address(Self.v6Bytes([], tail: [2]))))
    }

    @Test func aPrefixZeroMaskDeniesAllOfItsFamilyAndIsNotEmptyOrInvalid() throws {
        let anyV4 = try Self.mask(Self.v4Bytes(0, 0, 0, 0), 0)
        let anyV6 = try Self.mask(Self.v6Bytes([]), 0)
        let plainV4 = try Self.address(Self.v4Bytes(203, 0, 113, 9))
        let plainV6 = try Self.address(Self.v6Bytes([0x20, 0x01, 0x0D, 0xB8]))
        #expect(anyV4.matches(plainV4))
        #expect(!anyV4.matches(plainV6))
        #expect(anyV6.matches(plainV6))
        #expect(!anyV6.matches(plainV4))
        let policy = try Self.policy(denied: [anyV4])
        #expect(policy.decide(plainV4, origin: .discovered) == .refused(.denied(maskIndex: 0)))
        #expect(policy.decide(plainV6, origin: .discovered) == .allowed)
        #expect(policy.denied.count == 1)
    }

    @Test func aMappedAddressIsMatchedByIPv4MasksOnItsEmbeddedBytesAndByIPv6MasksOnAllBytes() throws {
        let mapped = try Self.address(Self.mappedBytes(8, 8, 8, 8))
        let native = try Self.address(Self.v4Bytes(8, 8, 8, 8))
        #expect(try Self.mask(Self.v4Bytes(8, 8, 8, 8), 32).matches(mapped))
        #expect(try Self.mask(Self.v4Bytes(8, 0, 0, 0), 8).matches(mapped))
        #expect(try Self.mask(Self.v4Bytes(9, 0, 0, 0), 8).matches(mapped) == false)
        let mappedBlock = try Self.mask(Self.v6Bytes([], tail: [0xFF, 0xFF, 0, 0, 0, 0]), 96)
        #expect(mappedBlock.matches(mapped))
        #expect(!mappedBlock.matches(native))
        #expect(!mappedBlock.matches(try Self.address(Self.v6Bytes([0x20, 0x01]))))
        let wrongBlock = try Self.mask(Self.v6Bytes([], tail: [0xFF, 0xFE, 0, 0, 0, 0]), 96)
        #expect(!wrongBlock.matches(mapped))
        #expect(try Self.mask(Self.v4Bytes(0, 0, 0, 0), 0).matches(mapped))
        #expect(try Self.mask(Self.v6Bytes([]), 0).matches(mapped))
    }

    @Test func aPolicyAcceptsSixtyFourDeniedMasksAndRefusesSixtyFiveWithTheLimit() throws {
        let one = try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8)
        #expect(try Self.policy(denied: []).denied.isEmpty)
        let limit = try Self.policy(denied: Array(repeating: one, count: 64))
        #expect(limit.denied.count == 64)
        #expect(PeerEndpointPolicy.maximumDenied == 64)
        #expect(throws: PeerEndpointRefusal.tooManyDenied(limit: 64)) {
            try Self.policy(denied: Array(repeating: one, count: 65))
        }
        #expect(throws: PeerEndpointRefusal.tooManyDenied(limit: 64)) {
            try Self.policy(denied: Array(repeating: one, count: 1_000))
        }
    }

    @Test func aPolicyKeepsItsFieldsAndTheCallerOrderOfTheDeniedMasks() throws {
        let first = try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8)
        let second = try Self.mask(Self.v4Bytes(192, 168, 0, 0), 16)
        let classes: Set<PeerAddressClass> = [.privateRange, .loopback]
        let policy = try Self.policy(allowed: classes, denied: [second, first], localLink: true, manual: false)
        #expect(policy.denied == [second, first])
        #expect(policy.allowedClasses == [.privateRange, .loopback])
        #expect(policy.requireLocalLink)
        #expect(!policy.manualEntryAllowed)
        let other = try Self.policy(allowed: classes, denied: [first, second], localLink: true, manual: false)
        #expect(other != policy)
    }

    @Test func theFirstMatchingMaskIndexIsReportedEvenWithDuplicates() throws {
        let miss = try Self.mask(Self.v4Bytes(1, 0, 0, 0), 8)
        let hit = try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8)
        let wide = try Self.mask(Self.v4Bytes(0, 0, 0, 0), 0)
        let policy = try Self.policy(denied: [miss, miss, wide, hit, hit])
        let target = try Self.address(Self.v4Bytes(10, 1, 1, 1))
        #expect(policy.decide(target, origin: .discovered) == .refused(.denied(maskIndex: 2)))
        let later = try Self.policy(denied: [miss, hit, hit])
        #expect(later.decide(target, origin: .manual) == .refused(.denied(maskIndex: 1)))
    }

    @Test func aDeniedAddressIsRefusedWhateverItsClassOriginOrAllowance() throws {
        let deny = try Self.mask(Self.v4Bytes(169, 254, 0, 0), 16)
        let other = try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8)
        let policy = try Self.policy(denied: [deny], localLink: true)
        let target = try Self.address(Self.v4Bytes(169, 254, 7, 7))
        #expect(target.classification == .linkLocal)
        #expect(policy.decide(target, origin: .discovered) == .refused(.denied(maskIndex: 0)))
        #expect(policy.decide(target, origin: .manual) == .refused(.denied(maskIndex: 0)))
        let shifted = try Self.policy(denied: [other, deny], localLink: true)
        #expect(shifted.decide(target, origin: .manual) == .refused(.denied(maskIndex: 1)))
        let neighbour = try Self.address(Self.v4Bytes(169, 255, 0, 0))
        #expect(policy.decide(neighbour, origin: .manual) == .refused(.notLocalLink))
        let mapped = try Self.address(Self.mappedBytes(169, 254, 7, 7))
        #expect(policy.decide(mapped, origin: .manual) == .refused(.denied(maskIndex: 0)))
    }

    @Test func aMappedPublicAddressCannotLaunderPastAClassOrDenialRule() throws {
        let onlyPrivate = try Self.policy(allowed: [.privateRange])
        let mapped = try Self.address(Self.mappedBytes(8, 8, 8, 8))
        #expect(onlyPrivate.decide(mapped, origin: .manual) == .refused(.classNotAllowed(.publicRange)))
        let denyDns = try Self.policy(denied: [try Self.mask(Self.v4Bytes(8, 8, 8, 8), 32)])
        #expect(denyDns.decide(mapped, origin: .manual) == .refused(.denied(maskIndex: 0)))
        let local = try Self.policy(localLink: true)
        #expect(local.decide(mapped, origin: .manual) == .refused(.notLocalLink))
        let mappedLoopback = try Self.address(Self.mappedBytes(127, 0, 0, 1))
        #expect(onlyPrivate.decide(mappedLoopback, origin: .manual) == .refused(.classNotAllowed(.loopback)))
    }

    @Test func manualEntryNeedsThePolicyToAllowItAndNeverOverridesAnyOtherRule() throws {
        let target = try Self.address(Self.v4Bytes(192, 168, 1, 5))
        let open = try Self.policy(manual: true)
        let closed = try Self.policy(manual: false)
        #expect(open.decide(target, origin: .manual) == .allowed)
        #expect(closed.decide(target, origin: .manual) == .refused(.manualEntryDisabled))
        #expect(closed.decide(target, origin: .discovered) == .allowed)
        let strict = try Self.policy(allowed: [.linkLocal], localLink: true, manual: true)
        #expect(strict.decide(target, origin: .manual) == .refused(.classNotAllowed(.privateRange)))
        #expect(strict.decide(target, origin: .discovered) == .refused(.classNotAllowed(.privateRange)))
    }

    @Test func aRefusedClassReportsTheAddressClassForEveryClass() throws {
        let samples: [(PeerAddressClass, [UInt8])] = [
            (.loopback, Self.v4Bytes(127, 0, 0, 1)), (.linkLocal, Self.v4Bytes(169, 254, 1, 1)),
            (.privateRange, Self.v4Bytes(10, 9, 9, 9)), (.publicRange, Self.v4Bytes(8, 8, 4, 4)),
            (.unspecified, Self.v4Bytes(0, 0, 0, 0)), (.multicast, Self.v4Bytes(224, 1, 1, 1)),
            (.broadcast, Self.v4Bytes(255, 255, 255, 255))
        ]
        #expect(samples.count == PeerAddressClass.allCases.count)
        for (expected, bytes) in samples {
            let target = try Self.address(bytes)
            let policy = try Self.policy(allowed: Set(PeerAddressClass.allCases).subtracting([expected]))
            #expect(policy.decide(target, origin: .discovered) == .refused(.classNotAllowed(expected)))
            let permits = try Self.policy(allowed: [expected])
            #expect(permits.decide(target, origin: .discovered) == .allowed)
        }
        let nothing = try Self.policy(allowed: [])
        #expect(nothing.decide(try Self.address(Self.v4Bytes(8, 8, 4, 4)), origin: .discovered)
            == .refused(.classNotAllowed(.publicRange)))
    }

    @Test func requiringLocalLinkAllowsOnlyLinkLocalAndAnExplicitlyAllowedLoopback() throws {
        let policy = try Self.policy(allowed: [.linkLocal, .loopback, .privateRange, .publicRange], localLink: true)
        let linkLocal = try Self.address(Self.v6Bytes([0xFE, 0x80]), zone: 4)
        #expect(policy.decide(linkLocal, origin: .manual) == .allowed)
        #expect(policy.decide(try Self.address(Self.v4Bytes(169, 254, 1, 1)), origin: .manual) == .allowed)
        #expect(policy.decide(try Self.address(Self.v4Bytes(127, 0, 0, 1)), origin: .manual) == .allowed)
        for bytes in [Self.v4Bytes(10, 0, 0, 1), Self.v4Bytes(8, 8, 8, 8), Self.v6Bytes([0xFD]), Self.v6Bytes([0x20])] {
            #expect(policy.decide(try Self.address(bytes), origin: .manual) == .refused(.notLocalLink), "\(bytes)")
        }
        let noLoopback = try Self.policy(allowed: [.linkLocal], localLink: true)
        #expect(noLoopback.decide(try Self.address(Self.v4Bytes(127, 0, 0, 1)), origin: .manual)
            == .refused(.classNotAllowed(.loopback)))
        let relaxed = try Self.policy(allowed: [.privateRange], localLink: false)
        #expect(relaxed.decide(try Self.address(Self.v4Bytes(10, 0, 0, 1)), origin: .manual) == .allowed)
    }

    @Test func decideLeavesThePolicyAndTheAddressUnchangedAfterEveryRefusal() throws {
        let deny = try Self.mask(Self.v4Bytes(10, 0, 0, 0), 8)
        let policy = try Self.policy(allowed: [.privateRange], denied: [deny], localLink: true, manual: false)
        let policyBefore = policy
        for bytes in [Self.v4Bytes(10, 1, 1, 1), Self.v4Bytes(192, 168, 1, 1), Self.v4Bytes(8, 8, 8, 8)] {
            let target = try Self.address(bytes, zone: nil)
            let targetBefore = target
            #expect(policy.decide(target, origin: .manual) != .allowed)
            #expect(policy.decide(target, origin: .discovered) != .allowed)
            #expect(policy == policyBefore)
            #expect(target == targetBefore)
        }
    }
}
