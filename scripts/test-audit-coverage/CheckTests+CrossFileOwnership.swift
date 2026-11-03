#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureTests {
    func crossFileOwnershipCases() {
        crossFileWitnessCases()
        crossFileMemberCases()
        crossFileReturnCases()
        crossFileRootCases()
        lookupConsumptionCases()
        contextualConsumptionCases()
        routingExtensionCases()
        routingLocalCases()
        routingShadowCases()
    }

    private func crossFileWorld(
        _ name: String, first: String, second: String, expected: Int, diagnostic: String? = nil
    ) throws {
        let fixture = try world(name, annotated: true)
        fixture.objects["iosB"] = ["isa": "PBXBuildFile", "fileRef": "fileB"]
        fixture.objects["iosSources"]?["files"] = ["iosA", "iosB"]
        fixture.manifest["sources"] = [
            ["target": "FluxKlangTests", "directories": ["Sources"], "files": ["Mac/B.swift"]],
            ["target": "FluxKlangMacTests", "directories": ["Mac"], "files": ["Sources/A.swift"]]
        ]
        let spec = "Reviewed fixture: iOS=Sources/** + Mac/B.swift; macOS=Mac/** + Sources/A.swift\n"
        try fixture.write("project.yml", spec)
        fixture.manifest["specification"] = [
            "path": "project.yml", "sha256": digest(Data(spec.utf8)), "review": "REVIEWED"
        ]
        try fixture.save()
        try fixture.register(fixture.run().derivedRegistrations)
        try require(fixture.run().enforcementSatisfied, "registered cross-file control failed")
        try fixture.write("Sources/A.swift",
                          "@Suite(.productionAccessAudit) struct Example { @Test func body() {} }\n" + first)
        try fixture.write("Mac/B.swift", second)
        for mode in ["enforce", "inventory"] {
            let report = fixture.run(mode: mode)
            try report.encoded().write(to: fixture.root.appendingPathComponent(mode + "-result.json"))
            try require(report.exitCode == expected && report.analysisComplete == (expected == 0) &&
                        report.enforcementSatisfied == (expected == 0), "cross-file ownership outcome: \(name)")
            if let diagnostic {
                try require(report.diagnostics.contains { $0.message.contains(diagnostic) },
                            "wrong cross-file refusal: \(name)")
            }
        }
    }

    private func crossFileWitnessCases() {
        let foreign = "private class Outer {}\nextension Outer { enum Names { class Parent {} } }"
        let sdk = """
        import class XCTest.XCTestCase
        class Base { enum Names { typealias Parent = XCTestCase } }
        private class Outer: Base { class Legacy: Names.Parent {} }
        """
        test("private extension members cannot mask another file's inherited SDK ancestry") {
            try crossFileWorld("cross-owner-sdk", first: foreign, second: sdk, expected: 2)
        }
        test("cross-file extension target identity survives reversed files and declaration order") {
            try crossFileWorld("cross-owner-reversed", first: sdk, second: foreign, expected: 2)
            for sources in [[("A.swift", foreign), ("B.swift", sdk)], [("B.swift", sdk), ("A.swift", foreign)]] {
                try rejects({ _ = try sourceReport(sources) }, containing: "XCTest")
            }
        }
        test("foreign members neither reject ordinary inheritance nor hide the unrelated SDK control") {
            let ordinary = sdk.replacingOccurrences(of: "import class XCTest.XCTestCase", with: "class Plain {}")
                .replacingOccurrences(of: "typealias Parent = XCTestCase", with: "typealias Parent = Plain")
            try crossFileWorld("cross-owner-ordinary", first: foreign, second: ordinary, expected: 0)
            try crossFileWorld("cross-owner-unrelated", first: foreign.replacingOccurrences(of: "Names", with: "Other"),
                               second: sdk, expected: 2)
        }
        test("fileprivate targets carry effective restrictions through unmodified extensions") {
            try crossFileWorld("cross-owner-fileprivate",
                               first: foreign.replacingOccurrences(of: "private", with: "fileprivate"),
                               second: sdk.replacingOccurrences(of: "private", with: "fileprivate"), expected: 2)
        }
    }

    private func crossFileMemberCases() {
        test("dotted extension targets bind nested owner identity rather than a foreign spelling") {
            try crossFileWorld("cross-owner-dotted", first: """
            private class Outer { struct Inner {} }
            extension Outer.Inner { enum Names { class Parent {} } }
            """, second: """
            import class XCTest.XCTestCase
            class Base { enum Names { typealias Parent = XCTestCase } }
            private class Outer { class Inner: Base { class Legacy: Names.Parent {} } }
            """, expected: 2)
        }
        test("foreign extension alias members cannot replace the actual inherited alias") {
            try crossFileWorld("cross-owner-alias", first: """
            class Plain {}
            private class Outer {}
            extension Outer { enum Names { typealias Parent = Plain } }
            """, second: """
            import class XCTest.XCTestCase
            class Base { enum Names { typealias Parent = XCTestCase } }
            private class Outer: Base { class Legacy: Names.Parent {} }
            """, expected: 2)
        }
        test("supported visible cross-file extension members remain ordinary ancestry bindings") {
            try crossFileWorld("cross-owner-visible", first: """
            class Outer {}
            extension Outer { enum Names { class Parent {} } }
            """, second: "class Helper: Outer.Names.Parent {}", expected: 0)
        }
        test("nearer own ordinary members are not polluted by a foreign extension or inherited SDK alias") {
            try crossFileWorld("cross-owner-nearer", first: """
            import class XCTest.XCTestCase
            private class Outer {}
            extension Outer { enum Names { typealias Parent = XCTestCase } }
            """, second: """
            import class XCTest.XCTestCase
            class Plain {}
            class Base { enum Names { typealias Parent = XCTestCase } }
            private class Outer: Base {
                enum Names { typealias Parent = Plain }
                class Helper: Names.Parent {}
            }
            """, expected: 0)
        }
    }

    private func crossFileReturnCases() {
        let foreign = """
        private class Outer {}
        extension Outer { enum Names { struct Result {} } }
        """
        let declarations = """
        class Base<T> { enum Names { typealias Result = Void } }
        typealias Parent<T> = Base<T>
        private class Outer: Parent<Int> {
        """
        test("foreign return nominal cannot establish non-Void over an inherited Void alias") {
            try crossFileWorld("cross-owner-void", first: foreign,
                               second: declarations + "func testUtility() -> Names.Result {} }", expected: 2)
        }
        test("identity correction preserves syntactically non-Void generic-ancestry helpers") {
            try crossFileWorld("cross-owner-function-return", first: foreign,
                               second: declarations + "func testUtility() -> () -> Void { {} } }", expected: 0)
        }
        test("unresolved extension ownership never proves a nominal return binding") {
            // Model-only unresolved target: this is not asserted to compile.
            try crossFileWorld("cross-owner-unresolved-return", first:
                "extension Missing { struct Result {} }", second:
                "class Helper: Unknown { func testUtility() -> Missing.Result {} }", expected: 2)
        }
    }

    private func crossFileRootCases() {
        test("Testing dotted extensions share private owner identity with member lookup") {
            let sources = [
                ("A.swift", """
                @Suite(.productionAccessAudit) private struct Outer { struct Inner {} }
                extension Outer.Inner { @Test func first() {} }
                """),
                ("B.swift", """
                @Suite(.productionAccessAudit) private struct Outer { struct Inner {} }
                extension Outer.Inner { @Test func second() {} }
                """)
            ]
            let report = try sourceReport(sources)
            try require(report.enforcementSatisfied && report.ownership.count == 2, "private roots conflated")
            for row in report.ownership {
                try require(row.tests.count == 1 && row.tests[0].path == row.registration.path,
                            "extension test assigned to foreign root")
            }
            try require(try report.encoded() == sourceReport(Array(sources.reversed())).encoded(),
                        "root ownership depends on declaration order")
        }
        test("effective target and enclosing restrictions cannot expose a private nested root") {
            for modifier in ["private", "fileprivate"] {
                try rejects {
                    _ = try sourceReport([
                        ("A.swift", "\(modifier) struct Outer {}\nextension Outer { struct Inner {} }"),
                        ("B.swift", "extension Outer.Inner { @Test func body() {} }")
                    ])
                }
            }
        }
        test("ambiguous unsupported alias and cyclic extension targets remain indeterminate model controls") {
            // Duplicate declarations, unresolved/cyclic aliases and unsupported
            // constraints are source-model controls, not compiler-valid witnesses.
            for definitions in [
                "struct Outer {}\nstruct Outer {}",
                "typealias Outer = Missing",
                "typealias Outer = Other\ntypealias Other = Outer",
                "struct Generic<T> {}\ntypealias Outer = Generic<Int>"
            ] {
                try rejects {
                    _ = try sourceReport([("A.swift", definitions),
                                          ("B.swift", "extension Outer { @Test func body() {} }")])
                }
            }
            try rejects {
                _ = try sourceReport([("A.swift", "struct Outer<T> {}"),
                                      ("B.swift", "extension Outer where T: Equatable { @Test func body() {} }")])
            }
        }
    }

    private func lookupConsumptionCases() {
        test("consumed external extension alias cannot hide compiler-proven SDK ancestry") {
            // Unsupported specialized spelling is a model-only control: NSObject
            // is not generic. Raw ancestry must not erase indexed provenance.
            try crossFileWorld("lookup-consumed-raw-model", first: """
            import Foundation
            import class XCTest.XCTestCase
            extension NSObject { typealias AuditParent = XCTestCase }
            class Legacy: NSObject<Int>.AuditParent {}
            """, second: "", expected: 2, diagnostic: "indeterminate source-bound XCTest ancestry")
            try crossFileWorld("lookup-consumed-sdk", first: """
            import Foundation
            import class XCTest.XCTestCase
            extension NSObject { typealias AuditParent = XCTestCase }
            class Legacy: NSObject.AuditParent {}
            """, second: "", expected: 2, diagnostic: "indeterminate source-bound XCTest ancestry")
        }
        test("consumed ordinary external extension provenance is conservatively unsupported") {
            // Compiler-proven Plain ancestry, not XCTest ancestry. The checker
            // still cannot justify an external extension's target identity.
            try crossFileWorld("lookup-consumed-ordinary", first: """
            import Foundation
            class Plain {}
            extension NSObject { typealias AuditParent = Plain }
            class Helper: NSObject.AuditParent {}
            """, second: "", expected: 2, diagnostic: "indeterminate source-bound XCTest ancestry")
        }
        test("unconsumed external extension helpers retain ordinary source enforcement") {
            try crossFileWorld("lookup-unconsumed", first: """
            import Foundation
            import class XCTest.XCTestCase
            extension NSObject { typealias AuditParent = XCTestCase }
            class Plain {}
            class Helper: Plain {}
            """, second: "", expected: 0)
        }
        let foreign = "private class Outer {}\nextension Outer { class Parent {} }"
        test("proven foreign lexical member permits the ordinary global alias") {
            try crossFileWorld("lookup-outward-ordinary", first: foreign, second: """
            class Plain {}
            typealias Parent = Plain
            private class Outer { class Helper: Parent {} }
            """, expected: 0)
        }
        test("outward SDK alias is rejected as XCTest ancestry rather than foreign ambiguity") {
            try crossFileWorld("lookup-outward-sdk", first: foreign, second: """
            import class XCTest.XCTestCase
            typealias Parent = XCTestCase
            private class Outer { class Legacy: Parent {} }
            """, expected: 2, diagnostic: "unsupported XCTest discovery-bearing class")
        }
    }
    private func contextualConsumptionCases() {
        for placement in ["nested", "extension"] {
            let prefix = """
            import Foundation
            import class XCTest.XCTestCase
            extension NSObject { typealias AuditParent = XCTestCase }
            class Plain {}

            """
            let wrapper = placement == "nested"
                ? "class Container: Plain { class Legacy: NSObject.AuditParent {} }"
                : "class Container: Plain {}\nextension Container { class Legacy: NSObject.AuditParent {} }"
            test("contextual \(placement) consumed external alias cannot hide SDK ancestry") {
                try crossFileWorld("context-\(placement)-sdk", first: prefix + wrapper, second: "", expected: 2,
                                   diagnostic: "indeterminate contextual source-bound XCTest ancestry")
                // Model-only: NSObject is not generic. Both named and raw
                // contextual ancestry must retain consumed source provenance.
                try crossFileWorld("context-\(placement)-raw-model", first: prefix +
                    wrapper.replacingOccurrences(of: "NSObject.AuditParent", with: "NSObject<Int>.AuditParent"),
                                   second: "", expected: 2,
                                   diagnostic: "indeterminate contextual source-bound XCTest ancestry")
            }
            test("contextual \(placement) consumed ordinary external provenance is conservatively unsupported") {
                // Compiler-valid Plain ancestry does not justify the external
                // extension's identity within this bounded source model.
                try crossFileWorld("context-\(placement)-ordinary", first:
                    prefix.replacingOccurrences(of: "= XCTestCase", with: "= Plain") + wrapper,
                                   second: "", expected: 2,
                                   diagnostic: "indeterminate contextual source-bound XCTest ancestry")
            }
            test("contextual \(placement) unconsumed external aliases preserve ordinary helpers") {
                try crossFileWorld("context-\(placement)-unconsumed", first: prefix +
                    wrapper.replacingOccurrences(of: "NSObject.AuditParent", with: "Plain")
                        .replacingOccurrences(of: "Legacy", with: "Helper"),
                                   second: "", expected: 0)
            }
        }
        test("contextual direct XCTestCase inheritance remains discovery-bearing") {
            try crossFileWorld("context-direct-sdk", first: """
            import class XCTest.XCTestCase
            class Plain {}
            class Container: Plain { class Legacy: XCTestCase {} }
            """, second: "", expected: 2, diagnostic: "unsupported XCTest discovery-bearing class")
        }
    }
}
extension FixtureTests {
    private var routingPrefix: String {
        """
        import Foundation
        import class XCTest.XCTestCase
        class Plain {}
        extension NSObject { typealias AuditParent = XCTestCase }

        """
    }

    private func routingExtensionCases() {
        for placement in ["direct", "intervening"] {
            for kind in ["sdk", "ordinary", "unconsumed"] {
                let member = kind == "unconsumed" ? "class Helper: Plain {}" :
                    "class Legacy: NSObject.AuditParent {}"
                let body = placement == "direct" ? member : "struct Middle { \(member) }"
                let prefix = kind == "ordinary" ?
                    routingPrefix.replacingOccurrences(of: "= XCTestCase", with: "= Plain") : routingPrefix
                test("routing \(placement) plain extension \(kind)") {
                    try crossFileWorld("routing-\(placement)-\(kind)", first: prefix +
                        "class Container {}\nextension Container { \(body) }", second: "",
                                       expected: kind == "unconsumed" ? 0 : 2)
                }
            }
        }
    }

    private func routingLocalCases() {
        let cases = [
            ("sdk", routingPrefix, "class Legacy: NSObject.AuditParent {}"),
            ("consumed-ordinary", routingPrefix.replacingOccurrences(of: "= XCTestCase", with: "= Plain"),
             "class Legacy: NSObject.AuditParent {}"),
            ("unconsumed", routingPrefix, "class Helper: Plain {}"),
            ("direct-sdk", "import class XCTest.XCTestCase\n", "class Legacy: XCTestCase {}"),
            ("plain-no-alias", "class Plain {}\n", "class Helper: Plain {}")
        ]
        for (name, prefix, body) in cases {
            test("routing local \(name) preserves conservative source-binding boundary") {
                // Local Helper:Plain is unsupported even without the unused alias;
                // compiler validity does not extend the supported local source model.
                try crossFileWorld("routing-local-\(name)", first:
                    prefix + "private func localScope() {\n    \(body)\n}", second: "", expected: 2)
            }
        }
        for alias in [false, true] {
            for (name, body) in [("baseless", "class Helper {}"), ("external", "class Helper: Unindexed.Parent {}")] {
                test("routing local \(name) helper with unused alias \(alias)") {
                    // The unindexed external spelling is a structural helper
                    // control, not a compiler-valid SDK ancestry claim.
                    try crossFileWorld("routing-local-\(name)-\(alias)", first:
                        (alias ? routingPrefix : "") + "private func localScope() { \(body) }",
                                       second: "", expected: 0)
                }
            }
        }
        for spelling in ["(NSObject.AuditParent)", "NSObject<Int>.AuditParent"] {
            let name = spelling.hasPrefix("(") ? "parenthesized" : "raw"
            test("routing local \(name) retained ancestry spelling refuses indexed consumption") {
                // Structural-only paths; NSObject is not generic. No new static
                // compiler proof is asserted for these parenthesized/raw subcases.
                try crossFileWorld("routing-local-\(name)", first: routingPrefix +
                    "private func localScope() { class Legacy: \(spelling) {} }", second: "", expected: 2)
            }
        }
    }

    private func routingShadowCases() {
        test("routing extension first-component namespace shadows external provenance") {
            try crossFileWorld("routing-shadow-namespace", first: routingPrefix + """
            class Container { enum NSObject { typealias AuditParent = Plain } }
            extension Container { class Helper: NSObject.AuditParent {} }
            """, second: "", expected: 0)
        }
        test("routing extension formal shadow cannot fall through to a global namespace") {
            // Source-model formal-shadow control; not claimed compiler-valid.
            try crossFileWorld("routing-shadow-formal", first: routingPrefix + """
            class Container<NSObject> {}
            extension Container { class Helper: NSObject.AuditParent {} }
            """, second: "", expected: 2)
        }
        test("routing local formal decline remains shadowing rather than global consumption") {
            // Structural-only generic superclass spelling. Its recorded formal
            // must prevent the local presence check from using the global index.
            try crossFileWorld("routing-local-formal", first: routingPrefix + """
            private func localScope() { class Helper<NSObject>: NSObject.AuditParent {} }
            """, second: "", expected: 0)
        }
        test("routing local namespace shadow never establishes a winning global or local binding") {
            try crossFileWorld("routing-local-namespace", first: routingPrefix + """
            private func localScope() {
                enum NSObject { typealias AuditParent = Plain }
                class Helper: NSObject.AuditParent {}
            }
            """, second: "", expected: 2)
        }
        test("routing extension inaccessible first component cannot establish absence") {
            try crossFileWorld("routing-inaccessible", first:
                "private class Namespace { class Parent {} }\nclass Container {}", second:
                "extension Container { class Helper: Namespace.Parent {} }", expected: 2)
        }
        test("routing extension ambiguous first component remains a structural refusal") {
            // Duplicate source declarations are a model-only ambiguity control.
            try crossFileWorld("routing-ambiguous", first:
                "class Namespace { class Parent {} }\nclass Namespace { class Parent {} }\nclass Container {}",
                               second: "extension Container { class Helper: Namespace.Parent {} }", expected: 2)
        }
    }
}
#endif
