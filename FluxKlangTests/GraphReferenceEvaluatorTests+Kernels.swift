import Testing
import Foundation
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphReferenceEvaluatorTests {
    @Test("GC3 mix sums in the given order and the order is observable")
    func referenceKernelMixOrderIsObservable() {
        let scratch: [Float] = [16_777_216, 1, -16_777_216]
        #expect(ReferenceKernels.mix(terms: [0, 1, 2], scratch: scratch, frame: 0)?.bitPattern == Float(0).bitPattern)
        #expect(ReferenceKernels.mix(terms: [0, 2, 1], scratch: scratch, frame: 0)?.bitPattern == Float(1).bitPattern)
        #expect(ReferenceKernels.mix(terms: [2, 1, 0], scratch: scratch, frame: 0)?.bitPattern == Float(1).bitPattern)
    }

    @Test("GC3 mix preserves duplicates and applies the frame offset to every term")
    func referenceKernelMixKeepsDuplicatesAndAddsFrame() {
        #expect(ReferenceKernels.mix(terms: [0, 0, 0], scratch: [1.5], frame: 0) == 4.5)
        let scratch: [Float] = [0, 0, 1, 2, 10, 20]
        #expect(ReferenceKernels.mix(terms: [0, 2, 4], scratch: scratch, frame: 1) == 22)
        #expect(ReferenceKernels.mix(terms: [4, 2, 0], scratch: scratch, frame: 0) == 11)
    }

    @Test("GC3 mix starts at positive zero for empty and single negative-zero input")
    func referenceKernelMixStartsAtPositiveZero() {
        #expect(ReferenceKernels.mix(terms: [], scratch: [], frame: 0)?.bitPattern == Float.zero.bitPattern)
        let negative = -Float.zero
        #expect(ReferenceKernels.mix(terms: [0], scratch: [negative], frame: 0)?.bitPattern == Float.zero.bitPattern)
        #expect(ReferenceKernels.mix(terms: [0, 1], scratch: [negative, negative], frame: 0)?.bitPattern
            == Float.zero.bitPattern)
    }

    @Test("GC3 mix refuses a non-finite intermediate even when the final sum is finite")
    func referenceKernelMixRefusesIntermediateOverflow() {
        let big = Float.greatestFiniteMagnitude
        let scratch: [Float] = [big, big, -big]
        #expect(ReferenceKernels.mix(terms: [0, 1, 2], scratch: scratch, frame: 0) == nil)
        #expect(ReferenceKernels.mix(terms: [0, 2, 1], scratch: scratch, frame: 0) == big)
        #expect(ReferenceKernels.mix(terms: [0, 0], scratch: [big], frame: 0) == nil)
        #expect(ReferenceKernels.mix(terms: [0], scratch: [.infinity], frame: 0) == nil)
        #expect(ReferenceKernels.mix(terms: [0], scratch: [.nan], frame: 0) == nil)
    }

    @Test("GC3 mapRow keeps bit patterns for a bit-copy row and sums otherwise")
    func referenceKernelMapRowBitCopyKeepsBitPatterns() {
        let tiny = Float.leastNonzeroMagnitude
        let scratch: [Float] = [-0.0, -tiny, tiny]
        let negativeZero = (-Float.zero).bitPattern
        let copy = RoutingRow(terms: [0], isBitCopy: true)
        #expect(ReferenceKernels.mapRow(copy, scratch: scratch, frame: 0)?.bitPattern == negativeZero)
        let single = RoutingRow(terms: [0], isBitCopy: false)
        #expect(ReferenceKernels.mapRow(single, scratch: scratch, frame: 0)?.bitPattern == Float.zero.bitPattern)
        let subnormal = RoutingRow(terms: [1], isBitCopy: true)
        #expect(ReferenceKernels.mapRow(subnormal, scratch: scratch, frame: 0)?.bitPattern == (-tiny).bitPattern)
        let pair = RoutingRow(terms: [1, 2], isBitCopy: false)
        #expect(ReferenceKernels.mapRow(pair, scratch: scratch, frame: 0)?.bitPattern == Float.zero.bitPattern)
        let shifted = RoutingRow(terms: [1], isBitCopy: true)
        #expect(ReferenceKernels.mapRow(shifted, scratch: [9, 7, 5], frame: 1) == 5)
    }

    @Test("GC3 mapRow reports a non-finite sum as nil")
    func referenceKernelMapRowReportsNonFiniteSum() {
        let big = Float.greatestFiniteMagnitude
        let row = RoutingRow(terms: [0, 1], isBitCopy: false)
        #expect(ReferenceKernels.mapRow(row, scratch: [big, big], frame: 0) == nil)
        #expect(ReferenceKernels.mapRow(row, scratch: [big, -big], frame: 0) == 0)
    }

    @Test("GC3 gain of one is bit exact for every finite sample")
    func referenceKernelGainOfOneIsBitExact() {
        let samples: [Float] = [
            -0.0, 0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude, .greatestFiniteMagnitude, 1.5
        ]
        for sample in samples {
            #expect(ReferenceKernels.gain(sample, by: 1)?.bitPattern == sample.bitPattern)
        }
    }

    @Test("GC3 gain multiplies in Float32 and refuses a non-finite product")
    func referenceKernelGainExactValuesAndOverflow() {
        #expect(ReferenceKernels.gain(3, by: 0.5) == 1.5)
        #expect(ReferenceKernels.gain(-3, by: 2) == -6)
        #expect(ReferenceKernels.gain(-0.0, by: 0.5)?.bitPattern == (-Float.zero).bitPattern)
        #expect(ReferenceKernels.gain(.leastNonzeroMagnitude, by: 0.5)?.bitPattern == Float.zero.bitPattern)
        #expect(ReferenceKernels.gain(.greatestFiniteMagnitude, by: 2) == nil)
        #expect(ReferenceKernels.gain(.greatestFiniteMagnitude, by: 0.5) == Float.greatestFiniteMagnitude / 2)
        #expect(ReferenceKernels.gain(.infinity, by: 1) == nil)
        #expect(ReferenceKernels.gain(.nan, by: 1) == nil)
    }

    @Test("GC3 mute always returns positive zero")
    func referenceKernelMuteReturnsPositiveZero() {
        for sample in [-Float.zero, .nan, .infinity, -.infinity, 5, .leastNonzeroMagnitude] {
            #expect(ReferenceKernels.mute(sample).bitPattern == Float.zero.bitPattern)
        }
    }
}
