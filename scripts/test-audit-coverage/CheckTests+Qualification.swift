#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureTests {
    func qualificationCases() {
        test("v2 valid closure reports sixteen separate rows and retains audited obligations") {
            let fixture = try qualificationWorld("qualification-valid")
            let unregistered = fixture.run(mode: "inventory")
            try unregistered.encoded().write(to: fixture.root.appendingPathComponent("unregistered-result.json"))
            try require(unregistered.analysisComplete && unregistered.exitCode == 0 &&
                        !unregistered.enforcementSatisfied && unregistered.qualification?.contractSatisfied == true,
                        "valid unregistered v2 analysis failed: \(unregistered.diagnostics)")
            try fixture.register(unregistered.derivedRegistrations)
            for mode in ["inventory", "enforce"] {
                let report = fixture.run(mode: mode)
                let data = try report.encoded()
                try data.write(to: fixture.root.appendingPathComponent(mode + "-result.json"))
                try require(report.exitCode == 0 && report.enforcementSatisfied &&
                            report.qualification?.contractSatisfied == true, "registered v2 control failed")
                let rows = report.qualification?.inventory ?? []
                try require(rows.count == 16 && report.ownership.count == 16, "role inventories were mixed")
                try require(Set(rows.map(\.configuration)) == ["Debug", "Release"] &&
                            Set(rows.map(\.guardExpression)) == SourceVariant.guards,
                            "qualification variants missing")
                try require(rows.filter(\.mainActor).count == 8 && rows.allSatisfy {
                    $0.ownerKind == "struct" && $0.methodLine > $0.ownerLine
                }, "actor/declaration-site inventory drift")
                try require(report.derivedRegistrations.allSatisfy {
                    $0.target != FixtureWorld.qualificationTarget
                }, "qualification created canonical obligations")
                for path in FixtureWorld.qualificationPaths {
                    let source = try Data(contentsOf: fixture.root.appendingPathComponent(path))
                    try require(report.inputHashes[path] == digest(source), "qualification input hash missing")
                }
                try require(data == fixture.run(mode: mode).encoded(), "nondeterministic qualification JSON")
                let (text, code) = AuditChecker.execute([
                    "--root", fixture.root.path, "--manifest", "fixture.json", "--mode", mode, "--format", "text"
                ])
                try text.write(to: fixture.root.appendingPathComponent(mode + "-result.txt"))
                try require(code == 0 && String(data: text, encoding: .utf8)?
                    .contains("qualification contractSatisfied=true inventory=16") == true,
                            "missing qualification text")
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                try require(object?["schemaVersion"] as? Int == 2 && object?["targetRoles"] != nil,
                            "missing v2 report envelope")
            }
        }
        test("v2 qualification success does not waive audited annotations or registrations") {
            for annotated in [false, true] {
                let fixture = try qualificationWorld("qualification-audit-\(annotated)", annotated: annotated)
                if !annotated { try fixture.register(fixture.run().derivedRegistrations) }
                for mode in ["inventory", "enforce"] {
                    let report = fixture.run(mode: mode)
                    try report.encoded().write(to: fixture.root.appendingPathComponent(mode + "-result.json"))
                    try require(report.analysisComplete && !report.enforcementSatisfied &&
                                report.exitCode == (mode == "inventory" ? 0 : 1) &&
                                report.qualification?.contractSatisfied == true,
                                "audited obligations were waived or made structural")
                    try require(report.diagnostics.contains {
                        $0.category == (annotated ? "registration" : "annotation")
                    }, "audited failure category lost")
                }
            }
        }
        qualificationIdentityCases()
        qualificationDiscoveryCases()
        qualificationReportCases()
    }

    private func qualificationIdentityCases() {
        test("qualification methods require actual direct owner identity rather than flattened root names") {
            let name = "ownerRequestsUseAppleAndHostileLiveMetadataCannotAffectInterpretation"
            let method = """
            @Test(.enabled(if: ProcessInfo.processInfo.environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] == "1"))
            func \(name)() async throws {}
            """
            let replacements = [
                "struct FoundationModelActionLiveTests { struct Nested { \(method) } }",
                "struct FoundationModelActionLiveTests {}\nextension FoundationModelActionLiveTests { \(method) }",
                "struct FoundationModelActionLiveTests {}\n\(method)",
                "struct Other { \(method) }\ntypealias FoundationModelActionLiveTests = Other",
                "enum FoundationModelActionLiveTests { \(method) }",
                "class FoundationModelActionLiveTests { \(method) }",
                "actor FoundationModelActionLiveTests { \(method) }",
                "struct FoundationModelActionLiveTests<T> { \(method) }",
                "struct FoundationModelActionLiveTests { \(method)\nfunc \(name)(_ value: Int) {} }",
                "struct FoundationModelActionLiveTests { \(method)\n\(method) }",
                "struct FoundationModelActionLiveTests { \(method)\nfunc helper() {} }",
                "struct FoundationModelActionLiveTests { \(method) }\n" +
                    "extension FoundationModelActionLiveTests { func \(name)(_ value: Int) {} }",
                "struct FoundationModelActionLiveTests { \(method) }\n" +
                    "typealias Alias = FoundationModelActionLiveTests\nextension Alias { func helper() {} }",
                "struct Renamed { \(method) }"
            ]
            for (number, source) in replacements.enumerated() {
                let fixture = try qualificationWorld("qualification-owner-\(number)")
                try fixture.write(FixtureWorld.qualificationPaths[0], source)
                try rejectRoleFixture(fixture)
            }
        }
        test("qualification signatures actor and opt-in grammar reject substitutions and extra traits") {
            let mutations = [
                ("func ownerRequests", "static func ownerRequests"),
                ("func ownerRequests", "@MainActor func ownerRequests"),
                ("func ownerRequests", "nonisolated func ownerRequests"),
                ("() async throws", "<T>() async throws"),
                ("() async throws", "(_ value: Int) async throws"),
                ("() async throws", "() throws"),
                ("() async throws", "() async"),
                ("() async throws", "() async throws -> Void"),
                ("() async throws", "() async throws where Self: Sendable"),
                ("ownerRequestsUseAppleAndHostileLiveMetadataCannotAffectInterpretation", "renamed"),
                ("== \"1\"", "!= \"0\""),
                ("== \"1\"", "== \"true\""),
                ("ProcessInfo.processInfo.environment[\"FLUXKLANG_RUN_APPLE_MODEL_TESTS\"] == \"1\"", "true"),
                ("FLUXKLANG_RUN_APPLE_MODEL_TESTS", "OTHER_FLAG"),
                ("ProcessInfo.processInfo.environment", "environment"),
                ("@Test(", "@Test(.serialized, "),
                ("@Test(", "@Test(\"description\", "),
                ("@Test(", "@Test(.productionAccessAudit, "),
                ("@Test(", "@Test(arguments: [1], "),
                ("@Test(", "@Test @Test("),
                ("@Test(", "@Testing.Test("),
                ("@Test(", "@Suite("),
                ("struct Foundation", "@Suite struct Foundation"),
                ("struct Foundation", "@Suite(.productionAccessAudit) struct Foundation"),
                ("struct Foundation", "@MainActor struct Foundation"),
                ("struct Foundation", "@available(iOS 27, *) struct Foundation")
            ]
            for (number, mutation) in mutations.enumerated() {
                let fixture = try qualificationWorld("qualification-signature-\(number)")
                let original = FixtureWorld.qualificationSources[0]
                let changed = original.replacingOccurrences(of: mutation.0, with: mutation.1)
                try require(changed != original, "signature mutation did not apply")
                try fixture.write(FixtureWorld.qualificationPaths[0], changed)
                try rejectRoleFixture(fixture)
            }
            let actor = try qualificationWorld("qualification-missing-actor")
            try actor.write(FixtureWorld.qualificationPaths[1],
                            FixtureWorld.qualificationSources[1].replacingOccurrences(of: "@MainActor", with: ""))
            try rejectRoleFixture(actor, category: "qualification")
        }
    }

    private func qualificationDiscoveryCases() {
        test("all three qualification sources reject real conditionals even in inactive branches and bodies") {
            for index in 0..<3 {
                for (number, suffix) in [
                    "\n#if false\nstruct Hidden {}\n#endif",
                    "\n#if DEBUG\nlet debugOnly = true\n#endif",
                    "\nfunc helper() {\n#if canImport(FoundationModels)\nlet value = 1\n#endif\n}",
                    "\n#if canImport(FluxKlangMac)\n#if false\n@Test func hidden() {}\n#endif\n#endif"
                ].enumerated() {
                    let fixture = try qualificationWorld("qualification-conditional-\(index)-\(number)")
                    try fixture.write(FixtureWorld.qualificationPaths[index],
                                      FixtureWorld.qualificationSources[index] + suffix)
                    try rejectRoleFixture(fixture, category: "qualification")
                }
            }
        }
        test("qualification closure retains unsupported macro XCTest ancestry and local discovery refusal") {
            let additions = [
                "@CustomMacro struct Hidden {}",
                "#makeTests()",
                "func helper() { #unknownExpression() }",
                "import XCTest\nclass Hidden: XCTestCase {}",
                "import XCTest\ntypealias Base = XCTestCase\nclass Hidden: Base {}",
                "class Hidden: ExternalBase { func testAccess() {} }",
                "func helper() { struct Local { @Test func testBody() {} } }",
                "struct Helper { var value: Int { struct Local { @Test func testBody() {} }; return 0 } }",
                "struct Helper { @Test func extra() {} }",
                "@Suite struct Helper {}",
                "@Test func extra() {}",
                "struct Helper { @Suite var misplaced: Int = 0 }",
                "struct Broken {"
            ]
            for (number, addition) in additions.enumerated() {
                let fixture = try qualificationWorld("qualification-discovery-\(number)")
                try fixture.write(FixtureWorld.qualificationPaths[2],
                                  FixtureWorld.qualificationSources[2] + "\n" + addition)
                try rejectRoleFixture(fixture)
                if number == 8 {
                    try require(fixture.run().diagnostics.contains {
                        $0.category == "qualification" && $0.site != nil && $0.registration == nil
                    }, "extra qualification test diagnostic lost its available declaration site")
                }
            }
        }
        test("audited structural discovery in every symbolic variant precedes qualification obligations") {
            for configuration in ["DEBUG", "!DEBUG"] {
                for mac in ["canImport(FluxKlangMac)", "!canImport(FluxKlangMac)"] {
                    for models in ["canImport(FoundationModels)", "!canImport(FoundationModels)"] {
                        let fixture = try qualificationWorld("qualification-order-\(configuration)-\(mac)-\(models)")
                        try fixture.write("Sources/A.swift", """
                        @Suite(.productionAccessAudit) struct Example { @Test func body() {} }
                        #if \(configuration) && \(mac) && \(models)
                        import XCTest
                        class Hidden: XCTestCase {}
                        #endif
                        """)
                        // Simultaneous role-obligation failure must not bypass discovery.
                        try fixture.write(FixtureWorld.qualificationPaths[1],
                                          FixtureWorld.qualificationSources[1]
                            .replacingOccurrences(of: "@MainActor", with: ""))
                        try rejectRoleFixture(fixture, category: "model")
                        let report = fixture.run()
                        try require(report.qualification?.inventory.isEmpty == true &&
                                    !report.diagnostics.contains { $0.category == "qualification" },
                                    "qualification obligations selected before complete discovery")
                    }
                }
            }
            let duplicate = try qualificationWorld("qualification-order-duplicate-free")
            try duplicate.write("Sources/A.swift", "@Test func repeated() {}\n@Test func repeated() {}")
            try duplicate.write(FixtureWorld.qualificationPaths[1],
                                FixtureWorld.qualificationSources[1].replacingOccurrences(of: "@MainActor", with: ""))
            try rejectRoleFixture(duplicate, category: "model")
            try require(!duplicate.run().diagnostics.contains { $0.category == "qualification" },
                        "duplicate audited free declarations were discovered only after role obligations")
        }
    }

    private func qualificationReportCases() {
        test("v2 structural and changed-input failures cannot retain a satisfied qualification contract") {
            for (number, path) in FixtureWorld.qualificationPaths.enumerated() {
                let fixture = try qualificationWorld("qualification-recheck-\(number)")
                try fixture.register(fixture.run().derivedRegistrations)
                var report = fixture.run()
                try require(report.qualification?.contractSatisfied == true, "recheck control failed")
                let inputs = try SafeInputs(root: fixture.root.path)
                for source in FixtureWorld.qualificationPaths { _ = try inputs.read(source, role: .source) }
                try fixture.write(path, FixtureWorld.qualificationSources[number] + "\n// changed after capture")
                do {
                    try inputs.verifyUnchanged()
                    throw AuditFailure("changed qualification source escaped input recheck")
                } catch {
                    try require(String(describing: error).contains("input changed"),
                                "unexpected recheck error: \(error)")
                    report.diagnostics.append(AuditDiagnostic(
                        category: "input", message: String(describing: error), registration: nil, site: nil))
                }
                report.finish()
                try report.encoded().write(to: fixture.root.appendingPathComponent("recheck-result.json"))
                try require(report.exitCode == 2 && !report.analysisComplete &&
                            report.qualification?.contractSatisfied == false, "stale contractSatisfied survived finish")
            }
        }
        test("v1 report JSON has no v2 role envelope and preserves complete unadopted semantics") {
            let fixture = try world("qualification-v1-report")
            try fixture.register(fixture.run().derivedRegistrations)
            for mode in ["enforce", "inventory"] {
                let report = fixture.run(mode: mode)
                let object = try JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any]
                try require(object?["schemaVersion"] as? Int == 1 && object?["targetRoles"] == nil &&
                            object?["qualification"] == nil && report.analysisComplete &&
                            !report.enforcementSatisfied &&
                            report.exitCode == (mode == "enforce" ? 1 : 0), "v1 report semantics drift")
            }
        }
    }
}
#endif
