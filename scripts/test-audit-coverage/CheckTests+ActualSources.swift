#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureTests {
    func u1Cases() {
        test("actual frozen U1 sources preserve imports helpers two roots and auxiliary constructor") {
            var sources: [(String, String)] = []
            for name in ["ProductionAccessScope.swift", "ProductionAccessScopeTests.swift"] {
                let data = try Data(contentsOf: u1Root.appendingPathComponent(name))
                guard let text = String(data: data, encoding: .utf8) else { throw AuditFailure("U1 fixture UTF8") }
                sources.append(("FluxKlangTests/" + name, text))
                print("U1_SOURCE \(name) sha256=\(digest(data))")
            }
            try require(sources[1].1.contains("@Suite(SuiteExitProbe(), .productionAccessAudit)"),
                        "U1 auxiliary constructor not preserved")
            for mac in [false, true] {
                let report = try sourceReport(sources, macImport: mac)
                try require(report.exitCode == 0 && report.ownership.count == 2, "U1 model failed")
                try require(Set(report.ownership.map { $0.registration.name }) ==
                            ["ProductionAccessScopeTests", "ProductionAccessScopeSuiteTests"], "wrong U1 roots")
                try require(report.ownership.allSatisfy { $0.annotationSatisfied },
                            "U1 roots must carry the canonical audit trait")
                try require(report.ownership.reduce(0) { $0 + $1.tests.count } == 9, "U1 test obligations missing")
            }
        }
    }

    func actualObservationCases() {
        test("actual Observation helpers preserve imports and remain ordinary helpers") {
            let names = ["AssistantMixerExecutionTests.swift", "AssistantActionPlanningTests.swift"]
            let sources = try names.map {
                ("FluxKlangTests/" + $0, try String(contentsOf: u1Root.appendingPathComponent($0), encoding: .utf8))
            }
            let report = try sourceReport(sources)
            try require(report.exitCode == 0 && report.analysisComplete && report.ownership.count == 2 &&
                        report.ownership.allSatisfy { $0.annotationSatisfied },
                        "standard Observable helpers changed source obligations")
        }
    }
}
#endif
