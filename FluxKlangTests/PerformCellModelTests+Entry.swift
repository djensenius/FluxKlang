import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformCellModelTests {
    static func resolve(_ typed: Double, unit: ParameterUnit = .decibels, extra: Double? = nil,
                        descriptor: ParameterDescriptor) -> PerformEntryResult {
        PerformNumericEntry.resolve(typed, unit: unit, descriptor: descriptor, extraCeiling: extra)
    }

    static func clamped(_ value: Double, _ reason: PerformClampReason, _ message: String) -> PerformEntryResult {
        .clamped(value, reason: reason, message: message)
    }

    @Test func typedValuesInsideTheLimitsAreAppliedUnchanged() throws {
        let mains = try Self.descriptor()
        for typed in [-120, -119.999, -8, -0.0, 0, (0.0).nextDown] as [Double] {
            #expect(Self.resolve(typed, descriptor: mains) == .applied(typed))
        }
        let noCeiling = try Self.descriptor(ceiling: nil)
        #expect(Self.resolve(6, descriptor: noCeiling) == .applied(6))
        #expect(Self.resolve((6.0).nextDown, descriptor: noCeiling) == .applied((6.0).nextDown))
    }

    @Test func typedBelowLowerClampsToLowerAtTheSmallestStepAndAtTheExtremes() throws {
        let mains = try Self.descriptor()
        let expected = Self.clamped(-120, .belowRange, "Clamped to minimum -120 dB")
        for typed in [(-120.0).nextDown, -121, -1e300, -Double.greatestFiniteMagnitude] {
            #expect(Self.resolve(typed, descriptor: mains) == expected)
        }
    }

    @Test func typedAboveCeilingClampsToCeilingFromTheSmallestStepUpToTheExtremes() throws {
        let mains = try Self.descriptor()
        let expected = Self.clamped(0, .aboveCeiling, "Clamped to ceiling 0 dB")
        for typed in [(0.0).nextUp, 0.5, 6, (6.0).nextUp, 7, Double.greatestFiniteMagnitude] {
            #expect(Self.resolve(typed, descriptor: mains) == expected)
        }
        #expect(Self.resolve(0, descriptor: mains) == .applied(0))
    }

    @Test func withoutACeilingTheUpperBoundClampsAsAboveRange() throws {
        let noCeiling = try Self.descriptor(ceiling: nil)
        let expected = Self.clamped(6, .aboveRange, "Clamped to maximum 6 dB")
        for typed in [(6.0).nextUp, 7, Double.greatestFiniteMagnitude] {
            #expect(Self.resolve(typed, descriptor: noCeiling) == expected)
        }
        let equalCeiling = try Self.descriptor(ceiling: 6)
        #expect(Self.resolve(6, descriptor: equalCeiling) == .applied(6))
        #expect(Self.resolve((6.0).nextUp, descriptor: equalCeiling) == expected)
    }

    @Test func anExtraCeilingBelowTheDescriptorCeilingWins() throws {
        let mains = try Self.descriptor()
        #expect(Self.resolve(-10, extra: -10, descriptor: mains) == .applied(-10))
        #expect(Self.resolve(-9.5, extra: -10, descriptor: mains)
            == Self.clamped(-10, .aboveCeiling, "Clamped to ceiling -10 dB"))
        #expect(Self.resolve((-10.0).nextUp, extra: -10, descriptor: mains)
            == Self.clamped(-10, .aboveCeiling, "Clamped to ceiling -10 dB"))
        #expect(Self.resolve(6, extra: -10, descriptor: mains)
            == Self.clamped(-10, .aboveCeiling, "Clamped to ceiling -10 dB"))
        let noCeiling = try Self.descriptor(ceiling: nil)
        #expect(Self.resolve(5, extra: 2.5, descriptor: noCeiling)
            == Self.clamped(2.5, .aboveCeiling, "Clamped to ceiling 2.5 dB"))
    }

    @Test func anExtraCeilingAboveTheDescriptorLimitsIsIgnored() throws {
        let mains = try Self.descriptor()
        let expected = Self.clamped(0, .aboveCeiling, "Clamped to ceiling 0 dB")
        for extra in [0.0, (0.0).nextUp, 3, 6, 100, Double.greatestFiniteMagnitude] {
            #expect(Self.resolve(1, extra: extra, descriptor: mains) == expected)
        }
        let noCeiling = try Self.descriptor(ceiling: nil)
        #expect(Self.resolve(7, extra: 100, descriptor: noCeiling)
            == Self.clamped(6, .aboveRange, "Clamped to maximum 6 dB"))
    }

    @Test func anExtraCeilingBelowTheLowerBoundIsInconsistentNotClampedBelowTheRange() throws {
        let mains = try Self.descriptor()
        let extra = (-120.0).nextDown
        #expect(Self.resolve(-120, extra: -120, descriptor: mains) == .applied(-120))
        #expect(Self.resolve(-50, extra: extra, descriptor: mains)
            == .refused(.inconsistent(.outOfRange(extra, lower: -120, upper: 6))))
        #expect(Self.resolve(-130, extra: extra, descriptor: mains)
            == .refused(.inconsistent(.aboveCeiling(-120, ceiling: extra))))
        #expect(Self.resolve(-120, extra: extra, descriptor: mains)
            == .refused(.inconsistent(.outOfRange(extra, lower: -120, upper: 6))))
    }

    @Test func steppedParametersRefuseNonIntegralValuesAndNeverRound() throws {
        let index = try Self.descriptor(unit: .index, lower: 1, upper: 12, ceiling: nil, curve: .stepped)
        for typed in [2.5, 2.000001, 1.9999999, 11.5, 0.5, 12.5, 100.25, -0.5] {
            #expect(Self.resolve(typed, unit: .index, descriptor: index) == .refused(.notIntegral(typed)))
        }
        #expect(Self.resolve(2, unit: .index, descriptor: index) == .applied(2))
        #expect(Self.resolve(1, unit: .index, descriptor: index) == .applied(1))
        #expect(Self.resolve(12, unit: .index, descriptor: index) == .applied(12))
        #expect(Self.resolve(0, unit: .index, descriptor: index)
            == Self.clamped(1, .belowRange, "Clamped to minimum 1"))
        #expect(Self.resolve(13, unit: .index, descriptor: index)
            == Self.clamped(12, .aboveRange, "Clamped to maximum 12"))
        let flag = try Self.descriptor(unit: .boolean, lower: 0, upper: 1, ceiling: nil, curve: .stepped)
        #expect(Self.resolve(0.5, unit: .boolean, descriptor: flag) == .refused(.notIntegral(0.5)))
        #expect(Self.resolve(1, unit: .boolean, descriptor: flag) == .applied(1))
        #expect(Self.resolve(2, unit: .boolean, descriptor: flag)
            == Self.clamped(1, .aboveRange, "Clamped to maximum 1"))
        #expect(Self.resolve(-1, unit: .boolean, descriptor: flag)
            == Self.clamped(0, .belowRange, "Clamped to minimum 0"))
    }

    @Test func aClampOntoAFractionalLimitOfASteppedParameterIsInconsistent() throws {
        let index = try Self.descriptor(unit: .index, lower: 1, upper: 12, ceiling: 5.5, curve: .stepped)
        #expect(Self.resolve(5, unit: .index, descriptor: index) == .applied(5))
        #expect(Self.resolve(6, unit: .index, descriptor: index) == .refused(.inconsistent(.notIntegral(5.5))))
        let open = try Self.descriptor(unit: .index, lower: 1, upper: 12, ceiling: nil, curve: .stepped)
        #expect(Self.resolve(8, unit: .index, extra: 7.5, descriptor: open)
            == .refused(.inconsistent(.notIntegral(7.5))))
        #expect(Self.resolve(7, unit: .index, extra: 7.5, descriptor: open) == .applied(7))
    }

    @Test func anIntegralCeilingOfASteppedParameterClampsAtNAndNPlusOne() throws {
        let index = try Self.descriptor(unit: .index, lower: 1, upper: 12, ceiling: 5, curve: .stepped)
        let expected = Self.clamped(5, .aboveCeiling, "Clamped to ceiling 5")
        #expect(Self.resolve(4, unit: .index, descriptor: index) == .applied(4))
        #expect(Self.resolve(5, unit: .index, descriptor: index) == .applied(5))
        #expect(Self.resolve(6, unit: .index, descriptor: index) == expected)
        #expect(Self.resolve(12, unit: .index, descriptor: index) == expected)
        #expect(Self.resolve(13, unit: .index, descriptor: index) == expected)
        #expect(Self.resolve(5.5, unit: .index, descriptor: index) == .refused(.notIntegral(5.5)))
        let open = try Self.descriptor(unit: .index, lower: 1, upper: 12, ceiling: nil, curve: .stepped)
        #expect(Self.resolve(7, unit: .index, extra: 7, descriptor: open) == .applied(7))
        #expect(Self.resolve(8, unit: .index, extra: 7, descriptor: open)
            == Self.clamped(7, .aboveCeiling, "Clamped to ceiling 7"))
    }

    @Test func aDescriptorWithTheWidestFiniteBoundsResolvesWithoutOverflow() throws {
        let widest = Double.greatestFiniteMagnitude
        let open = try Self.descriptor(lower: -widest, upper: widest, ceiling: nil, curve: .linear)
        #expect(Self.resolve(widest, descriptor: open) == .applied(widest))
        #expect(Self.resolve(-widest, descriptor: open) == .applied(-widest))
        #expect(Self.resolve(0, descriptor: open) == .applied(0))
        let capped = try Self.descriptor(lower: -widest, upper: widest, ceiling: widest.nextDown, curve: .linear)
        let result = Self.resolve(widest, descriptor: capped)
        guard case .clamped(let value, let reason, let message) = result else {
            Issue.record("expected a clamp, got \(result)")
            return
        }
        #expect(value == widest.nextDown)
        #expect(reason == .aboveCeiling)
        #expect(message.utf8.count == 19 + 309 + 3)
        #expect(message.hasPrefix("Clamped to ceiling 17976931348623"))
        #expect(message.hasSuffix(" dB"))
        #expect(Self.resolve(-widest, extra: -widest, descriptor: open) == .applied(-widest))
    }

    @Test func nonFiniteTypedValuesAndExtraCeilingsAreRefused() throws {
        let mains = try Self.descriptor()
        for typed in [Double.nan, .infinity, -.infinity] {
            #expect(Self.resolve(typed, descriptor: mains) == .refused(.nonFinite))
        }
        for extra in [Double.nan, .infinity, -.infinity] {
            #expect(Self.resolve(-8, extra: extra, descriptor: mains) == .refused(.nonFinite))
        }
    }

    @Test func entryRefusalsRunInTheOrderNonFiniteUnitIntegralityThenClamp() throws {
        let index = try Self.descriptor(unit: .index, lower: 1, upper: 12, ceiling: nil, curve: .stepped)
        #expect(Self.resolve(.nan, unit: .percent, descriptor: index) == .refused(.nonFinite))
        #expect(Self.resolve(2.5, unit: .percent, descriptor: index)
            == .refused(.unitMismatch(expected: .index, found: .percent)))
        #expect(Self.resolve(.infinity, unit: .index, extra: .nan, descriptor: index) == .refused(.nonFinite))
        #expect(Self.resolve(400.5, unit: .index, descriptor: index) == .refused(.notIntegral(400.5)))
        #expect(Self.resolve(0.5, unit: .index, descriptor: index) == .refused(.notIntegral(0.5)))
        let mains = try Self.descriptor()
        #expect(Self.resolve(-8, unit: .percent, descriptor: mains)
            == .refused(.unitMismatch(expected: .decibels, found: .percent)))
        #expect(Self.resolve(900, unit: .normalized, descriptor: mains)
            == .refused(.unitMismatch(expected: .decibels, found: .normalized)))
    }

    @Test func clampMessagesCarryTheUnitSymbolAndTheExactNumber() throws {
        let percent = try Self.descriptor(unit: .percent, lower: 0, upper: 100, ceiling: 80.5)
        #expect(Self.resolve(90, unit: .percent, descriptor: percent)
            == Self.clamped(80.5, .aboveCeiling, "Clamped to ceiling 80.5 %"))
        #expect(Self.resolve(-1, unit: .percent, descriptor: percent)
            == Self.clamped(0, .belowRange, "Clamped to minimum 0 %"))
        let normalized = try Self.descriptor(unit: .normalized, lower: 0.25, upper: 1, ceiling: nil)
        #expect(Self.resolve(2, unit: .normalized, descriptor: normalized)
            == Self.clamped(1, .aboveRange, "Clamped to maximum 1"))
        #expect(Self.resolve(0.1, unit: .normalized, descriptor: normalized)
            == Self.clamped(0.25, .belowRange, "Clamped to minimum 0.25"))
        let pan = try Self.descriptor(unit: .pan, lower: -1, upper: 1, ceiling: nil)
        #expect(Self.resolve(-1.5, unit: .pan, descriptor: pan)
            == Self.clamped(-1, .belowRange, "Clamped to minimum -1"))
        let tiny = try Self.descriptor(ceiling: 1e-5)
        #expect(Self.resolve(1, extra: nil, descriptor: tiny)
            == Self.clamped(1e-5, .aboveCeiling, "Clamped to ceiling 0.00001 dB"))
    }

    @Test func everyAppliedOrClampedValueSatisfiesTheDescriptorCheck() throws {
        let descriptors = try [
            Self.descriptor(), Self.descriptor(ceiling: nil), Self.descriptor(ceiling: 6),
            Self.descriptor(unit: .percent, lower: 0, upper: 100, ceiling: 50.5, curve: .linear)
        ]
        let typedValues: [Double] = [
            -.greatestFiniteMagnitude, -1e9, -121, (-120.0).nextDown, -120, (-120.0).nextUp, -50.5, -0.0, 0,
            (0.0).nextDown, (0.0).nextUp, 0.5, 5.5, 6, (6.0).nextUp, 50.5, (50.5).nextUp, 100, (100.0).nextUp,
            1e9, .greatestFiniteMagnitude
        ]
        let extras: [Double?] = [nil, -200, -120, -10, 0, 3, 6, 60]
        var applied = 0
        var clamped = 0
        var refused = 0
        for descriptor in descriptors {
            let unit = descriptor.fields.unit
            for typed in typedValues {
                for extra in extras {
                    switch Self.resolve(typed, unit: unit, extra: extra, descriptor: descriptor) {
                    case .applied(let value):
                        applied += 1
                        #expect(value == typed)
                        #expect(throws: Never.self) {
                            try descriptor.check(ParameterValue(value: value, unit: unit), ceiling: extra)
                        }
                    case .clamped(let value, _, _):
                        clamped += 1
                        #expect(throws: Never.self) {
                            try descriptor.check(ParameterValue(value: value, unit: unit), ceiling: extra)
                        }
                    case .refused(let refusal):
                        refused += 1
                        guard case .inconsistent = refusal else {
                            Issue.record("unexpected refusal \(refusal)")
                            continue
                        }
                    }
                }
            }
        }
        #expect(applied + clamped + refused == 4 * 21 * 8)
        #expect(applied > 0 && clamped > 0 && refused > 0)
    }
}
