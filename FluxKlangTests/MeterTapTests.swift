import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The producer-side meter tap (#66 MET1): peak accumulator, dBFS conversion and slot publisher. Tests live in
/// `MeterTapTests+{Fixtures,Accumulation,Invalid,Level,Publish,Bounds}.swift`; helpers are in `+Fixtures`.
@Suite("Meter tap producer (#66 MET1)", .productionAccessAudit)
struct MeterTapTests {
    /// A fixed stamp: the publisher must copy it unchanged to every slot it writes.
    static let stamp = TelemetryStamp(clockGeneration: 7, frame: 4_800)
}
