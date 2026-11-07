import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Run statistics (#74, slice LAT2): validated run records, nearest-rank percentiles, deadline and dropout evidence,
/// uncertainty notes, the lowest-stable-buffer observation and signed run comparisons. This root file holds the
/// shared builders and the controlled-variable tests; the other files extend the suite.
@Suite("Run statistics")
struct RunStatisticsTests {
    // MARK: Builders

    static func variables(buffer: Int = 128, rate: Int = 48_000, load: String = "load.a",
                          backend: String = "backend.a", workload: String = "work.a") throws -> RunVariables {
        try RunVariables.make(bufferFrames: buffer, sampleRateHz: rate, loadProfile: load, backend: backend,
                              workload: workload)
    }

    /// The base variables with exactly one of them changed.
    static func variant(of variable: RunVariable) throws -> RunVariables {
        switch variable {
        case .bufferFrames: try variables(buffer: 256)
        case .sampleRate: try variables(rate: 44_100)
        case .loadProfile: try variables(load: "load.b")
        case .backend: try variables(backend: "backend.b")
        case .workload: try variables(workload: "work.b")
        }
    }

    static func measurements(_ renders: [Int64], deadline: Int64 = 1_000, dropouts: Int = 0,
                             recoveries: [Int64] = []) -> RunMeasurements {
        RunMeasurements(renderNanoseconds: renders, deadlineNanoseconds: deadline, dropouts: dropouts,
                        recoveryNanoseconds: recoveries)
    }

    static func record(_ renders: [Int64], deadline: Int64 = 1_000, dropouts: Int = 0, recoveries: [Int64] = [],
                       variables: RunVariables? = nil, experiment: String? = nil) throws -> RunRecord {
        try RunRecord.make(variables: variables ?? self.variables(), experiment: experiment,
                           measurements: measurements(renders, deadline: deadline, dropouts: dropouts,
                                                      recoveries: recoveries))
    }

    /// The values 1...count in a fixed non-sorted order (37 is coprime with every count used by the tests).
    static func permuted(_ count: Int) -> [Int64] {
        (0..<count).map { Int64(($0 * 37) % count + 1) }
    }

    static func statistics(_ renders: [Int64], deadline: Int64 = 1_000) throws -> RunStatistics {
        RunStatistics.make(from: try record(renders, deadline: deadline))
    }

    // MARK: Controlled variables

    @Test func variablesAcceptTheBufferAndRateBoundsAndRefuseOneBeyond() throws {
        let low = try Self.variables(buffer: 1, rate: 1)
        #expect(low.bufferFrames == 1 && low.sampleRateHz == 1)
        let high = try Self.variables(buffer: 65_536, rate: 768_000)
        #expect(high.bufferFrames == 65_536 && high.sampleRateHz == 768_000)
        #expect(throws: RunRefusal.bufferFramesOutOfRange(0)) { try Self.variables(buffer: 0) }
        #expect(throws: RunRefusal.bufferFramesOutOfRange(65_537)) { try Self.variables(buffer: 65_537) }
        #expect(throws: RunRefusal.sampleRateOutOfRange(0)) { try Self.variables(rate: 0) }
        #expect(throws: RunRefusal.sampleRateOutOfRange(768_001)) { try Self.variables(rate: 768_001) }
    }

    @Test func identifiersAcceptOneAndMaximumBytesAndRefuseEmptyOversizedAndInvalidText() throws {
        let longest = String(repeating: "a", count: 128)
        #expect(try Self.variables(backend: "x").backend.rawValue == "x")
        #expect(try Self.variables(backend: longest).backend.rawValue == longest)
        #expect(throws: RunRefusal.invalidID(.backend, bytes: 0)) { try Self.variables(backend: "") }
        #expect(throws: RunRefusal.invalidID(.backend, bytes: 129)) {
            try Self.variables(backend: String(repeating: "a", count: 129))
        }
        #expect(throws: RunRefusal.invalidID(.workload, bytes: 3)) { try Self.variables(workload: "a b") }
        #expect(throws: RunRefusal.invalidID(.loadProfile, bytes: 5)) { try Self.variables(load: "caf\u{E9}") }
    }

    @Test func aCombiningMarkMakesAnIdentifierInvalidInsteadOfMergingNames() {
        #expect(throws: RunRefusal.invalidID(.loadProfile, bytes: 6)) { try Self.variables(load: "load\u{301}") }
    }

    @Test func variableRefusalsFollowBufferRateLoadBackendWorkloadOrder() {
        #expect(throws: RunRefusal.bufferFramesOutOfRange(0)) {
            try Self.variables(buffer: 0, rate: 0, load: "", backend: "", workload: "")
        }
        #expect(throws: RunRefusal.sampleRateOutOfRange(0)) {
            try Self.variables(rate: 0, load: "", backend: "", workload: "")
        }
        #expect(throws: RunRefusal.invalidID(.loadProfile, bytes: 0)) {
            try Self.variables(load: "", backend: "", workload: "")
        }
        #expect(throws: RunRefusal.invalidID(.backend, bytes: 0)) { try Self.variables(backend: "", workload: "") }
        #expect(throws: RunRefusal.invalidID(.workload, bytes: 0)) { try Self.variables(workload: "") }
    }

    @Test(arguments: RunVariable.allCases)
    func differingNamesExactlyTheChangedVariable(variable: RunVariable) throws {
        let base = try Self.variables()
        let changed = try Self.variant(of: variable)
        #expect(changed.differing(from: base) == [variable])
        #expect(base.differing(from: changed) == [variable])
        #expect(base.differing(from: base).isEmpty)
    }

    @Test func differingListsEveryChangedVariableInDeclarationOrder() throws {
        let base = try Self.variables()
        let changed = try Self.variables(buffer: 64, rate: 44_100, load: "load.b", backend: "backend.b",
                                         workload: "work.b")
        #expect(changed.differing(from: base) == [.bufferFrames, .sampleRate, .loadProfile, .backend, .workload])
        let some = try Self.variables(load: "load.b", workload: "work.b")
        #expect(some.differing(from: base) == [.loadProfile, .workload])
    }

    @Test func variableNamesAreStableReportLabels() {
        let names = RunVariable.allCases.map(\.name)
        #expect(names == ["bufferFrames", "sampleRate", "loadProfile", "backend", "workload"])
    }
}
