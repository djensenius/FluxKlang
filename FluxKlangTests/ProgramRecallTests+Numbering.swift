//
//  ProgramRecallTests+Numbering.swift
//  FluxKlangTests
//
//  `ProgramRecallNumbering`: the conversion between the internal 0...127 number and the number a device shows, for
//  the zero-based and the one-based display, with the value on each limit and the value one outside it.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProgramRecallTests {
    /// What `internalValue(displayed:base:)` produced: a value or a refusal.
    enum Converted: Equatable {
        case value(UInt8)
        case refused(ProgramRecallRefusal)
    }

    /// What `displayed(internalValue:base:)` produced: a number or a refusal.
    enum Shown: Equatable {
        case number(Int)
        case refused(ProgramRecallRefusal)
    }

    static func convert(_ displayed: Int, _ base: ProgramRecallNumbering.Base) -> Converted {
        do throws(ProgramRecallRefusal) {
            return .value(try ProgramRecallNumbering.internalValue(displayed: displayed, base: base))
        } catch {
            return .refused(error)
        }
    }

    static func show(_ value: UInt8, _ base: ProgramRecallNumbering.Base) -> Shown {
        do throws(ProgramRecallRefusal) {
            return .number(try ProgramRecallNumbering.displayed(internalValue: value, base: base))
        } catch {
            return .refused(error)
        }
    }

    @Test
    func aZeroBasedDisplayAcceptsZeroTo127AndRefusesMinusOneAnd128() {
        let atZero = Self.convert(0, .zeroBased)
        let atOne = Self.convert(1, .zeroBased)
        let atTop = Self.convert(127, .zeroBased)
        let belowZero = Self.convert(-1, .zeroBased)
        let pastTop = Self.convert(128, .zeroBased)
        #expect(atZero == Converted.value(0))
        #expect(atOne == Converted.value(1))
        #expect(atTop == Converted.value(127))
        #expect(belowZero == Converted.refused(.numberOutOfRange(-1)))
        #expect(pastTop == Converted.refused(.numberOutOfRange(128)))
    }

    @Test
    func aOneBasedDisplayAcceptsOneTo128AndRefusesZeroAnd129() {
        let atOne = Self.convert(1, .oneBased)
        let atTwo = Self.convert(2, .oneBased)
        let atTop = Self.convert(128, .oneBased)
        let atZero = Self.convert(0, .oneBased)
        let pastTop = Self.convert(129, .oneBased)
        #expect(atOne == Converted.value(0))
        #expect(atTwo == Converted.value(1))
        #expect(atTop == Converted.value(127))
        #expect(atZero == Converted.refused(.numberOutOfRange(0)))
        #expect(pastTop == Converted.refused(.numberOutOfRange(129)))
    }

    @Test
    func theSmallestAndLargestIntegersAreRefusedByBothBasesWithoutATrap() {
        let zeroLow = Self.convert(Int.min, .zeroBased)
        let zeroHigh = Self.convert(Int.max, .zeroBased)
        let oneLow = Self.convert(Int.min, .oneBased)
        let oneHigh = Self.convert(Int.max, .oneBased)
        #expect(zeroLow == Converted.refused(.numberOutOfRange(Int.min)))
        #expect(zeroHigh == Converted.refused(.numberOutOfRange(Int.max)))
        #expect(oneLow == Converted.refused(.numberOutOfRange(Int.min)))
        #expect(oneHigh == Converted.refused(.numberOutOfRange(Int.max)))
    }

    @Test
    func theDisplayedNumberIsTheInternalValueForZeroBasedAndOneMoreForOneBasedAtZeroAnd127() {
        let zeroAtZero = Self.show(0, .zeroBased)
        let zeroAtTop = Self.show(127, .zeroBased)
        let oneAtZero = Self.show(0, .oneBased)
        let oneAtTop = Self.show(127, .oneBased)
        #expect(zeroAtZero == Shown.number(0))
        #expect(zeroAtTop == Shown.number(127))
        #expect(oneAtZero == Shown.number(1))
        #expect(oneAtTop == Shown.number(128))
    }

    @Test
    func anInternalValueOf128And255IsRefusedForDisplayInBothBases() {
        let zeroPast = Self.show(128, .zeroBased)
        let zeroMaximum = Self.show(255, .zeroBased)
        let onePast = Self.show(128, .oneBased)
        let oneMaximum = Self.show(255, .oneBased)
        #expect(zeroPast == Shown.refused(.numberOutOfRange(128)))
        #expect(zeroMaximum == Shown.refused(.numberOutOfRange(255)))
        #expect(onePast == Shown.refused(.numberOutOfRange(128)))
        #expect(oneMaximum == Shown.refused(.numberOutOfRange(255)))
    }

    @Test
    func displayingAndConvertingBackReturnsEachOfThe128InternalValuesForBothBases() {
        var mismatches = 0
        for base in ProgramRecallNumbering.Base.allCases {
            for value in 0...127 {
                let internal8 = UInt8(value)
                guard case .number(let shown) = Self.show(internal8, base) else {
                    mismatches += 1
                    continue
                }
                if Self.convert(shown, base) != Converted.value(internal8) { mismatches += 1 }
            }
        }
        let wrong: Int = mismatches
        #expect(wrong == 0)
    }
}
