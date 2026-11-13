import Testing
import Foundation
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// GC3 (#66): reference evaluator, kernels and delay line. Fixtures live in `+Fixtures`.
@Suite(.productionAccessAudit)
struct GraphReferenceEvaluatorTests {
    static func bits(_ values: [Float]) -> [UInt32] {
        values.map(\.bitPattern)
    }
}
