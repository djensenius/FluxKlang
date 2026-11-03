#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureTests {
    func localProvenanceCases() {
        localAliasCases()
        localRegionCases()
        localShadowCases()
        localHelperCases()
        associatedOwnerCases()
    }

    private func localWorld(_ name: String, source: String, expected: Int) throws {
        let fixture = try world("local-provenance-" + name, annotated: true)
        try fixture.register(fixture.run().derivedRegistrations)
        try require(fixture.run().enforcementSatisfied, "registered local control failed")
        try fixture.write("Sources/A.swift",
                          "@Suite(.productionAccessAudit) struct Example { @Test func body() {} }\n" + source)
        for mode in ["enforce", "inventory"] {
            let report = fixture.run(mode: mode)
            try report.encoded().write(to: fixture.root.appendingPathComponent(mode + "-result.json"))
            try require(report.exitCode == expected && report.analysisComplete == (expected == 0) &&
                        report.enforcementSatisfied == (expected == 0), "local provenance outcome: \(name)")
            if expected == 0 {
                try require(report.diagnostics.isEmpty, "unexpected local helper diagnostics")
            }
        }
    }

    private func localAliasCases() {
        for (label, parent) in [("sdk", "XCTestCase"), ("ordinary", "Plain")] {
            let prefix = "import class XCTest.XCTestCase\nclass Plain {}\n"
            test("local \(label) alias consumption is unsupported, not resolved") {
                try localWorld(label + "-alias", source: prefix + """
                func helper() { typealias Parent = \(parent); class Legacy: Parent {} }
                """, expected: 2)
            }
            test("local \(label) namespace consumption is unsupported, not resolved") {
                try localWorld(label + "-namespace", source: prefix + """
                func helper() { enum Local { typealias Parent = \(parent) }; class Legacy: Local.Parent {} }
                """, expected: 2)
            }
            test("local \(label) parenthesized alias uses the same provenance prerequisite") {
                try localWorld(label + "-parenthesized", source: prefix + """
                func helper() { typealias Parent = \(parent); class Legacy: (Parent) {} }
                """, expected: 2)
            }
        }
        test("raw specialized local namespace ancestry is model-only, not a compiler claim") {
            try localWorld("raw", source: """
            func helper() {
                enum Local { typealias Parent<T> = XCTestCase }
                class Legacy: Local.Parent<Int> {}
            }
            """, expected: 2)
        }
        test("raw specialized unqualified local alias ancestry is model-only") {
            try localWorld("raw-unqualified", source: """
            func helper() { typealias Parent<T> = XCTestCase; class Legacy: Parent<Int> {} }
            """, expected: 2)
        }
        test("duplicate same-scope local aliases decline without choosing a binding; model-only") {
            try localWorld("duplicate", source: """
            func helper() {
                typealias Parent = Plain
                typealias Parent = XCTestCase
                class Legacy: Parent {}
            }
            """, expected: 2)
        }
    }

    private func localRegionCases() {
        let declaration = "typealias Parent = XCTestCase;"
        let consumer = "class Legacy: Parent {}"
        let regions = [
            ("block", "func helper() { \(declaration) do { \(consumer) } }"),
            ("closure", "let helper = { \(declaration) \(consumer) }"),
            ("nested-closure", "func helper() { \(declaration) let nested = { \(consumer) } }"),
            ("nested-function", "func helper() { \(declaration) func nested() { \(consumer) } }"),
            ("nominal-parent", "func helper() { \(declaration) enum Local { \(consumer) } }"),
            ("nominal-member", "func helper() { enum Local { \(declaration) \(consumer) } }"),
            ("switch-case", "func helper() { switch 0 { case 0: \(declaration) \(consumer); default: break } }")
        ]
        for (name, source) in regions {
            test("lexical \(name) local consumption is retained; structural fixture") {
                try localWorld(name, source: source, expected: 2)
            }
        }
        let siblings = [
            ("functions", "func first() { \(declaration) }\nfunc second() { \(consumer) }"),
            ("blocks", "func helper() { do { \(declaration) }; do { \(consumer) } }"),
            ("closures", "let first = { \(declaration) }; let second = { \(consumer) }"),
            ("cases", "func helper() { switch 0 { case 0: \(declaration) break; default: \(consumer) } }")
        ]
        for (name, source) in siblings {
            test("unrelated sibling \(name) cannot supply local provenance; unindexed model-only") {
                try localWorld("siblings-" + name, source: source, expected: 0)
            }
        }
        test("active conditional containers retain their lexical scope across all variants") {
            try localWorld("conditional", source: """
            func helper() {
            #if canImport(FluxKlangMac)
                typealias Parent = XCTestCase
            #else
                typealias Parent = Plain
            #endif
                class Legacy: Parent {}
            }
            """, expected: 2)
        }
        test("inactive local declarations do not contaminate unindexed ancestry; model-only") {
            try localWorld("inactive", source: """
            func helper() {
            #if false
                typealias Parent = XCTestCase
            #endif
                class Legacy: Parent {}
            }
            """, expected: 0)
        }
    }

    private func localShadowCases() {
        test("nearer ordinary local alias beside sibling SDK alias is conservatively unsupported") {
            try localWorld("sibling-shadow", source: """
            class Plain {}
            func first() { typealias Parent = XCTestCase }
            func second() { typealias Parent = Plain; class Legacy: Parent {} }
            """, expected: 2)
        }
        test("nearer ordinary namespace beside sibling SDK namespace is conservatively unsupported") {
            try localWorld("namespace-shadow", source: """
            class Plain {}
            func first() { enum Local { typealias Parent = XCTestCase } }
            func second() { enum Local { typealias Parent = Plain }; class Legacy: Local.Parent {} }
            """, expected: 2)
        }
        test("nearer ordinary local alias beside global SDK alias is not an SDK binding proof") {
            try localWorld("global-shadow", source: """
            class Plain {}
            typealias Parent = XCTestCase
            func helper() { typealias Parent = Plain; class Legacy: Parent {} }
            """, expected: 2)
        }
        test("nominal generic formal stops farther local namespace provenance; model-only") {
            try localWorld("formal", source: """
            func helper() {
                enum Local { typealias Parent = XCTestCase }
                class Helper<Local>: Local.Parent {}
            }
            """, expected: 0)
        }
        test("function generic formal stops farther local namespace provenance; model-only") {
            try localWorld("function-formal", source: """
            func helper() {
                enum Local { typealias Parent = XCTestCase }
                func nested<Local>() { class Helper: Local.Parent {} }
            }
            """, expected: 0)
        }
        test("backticks preserve local identifier identity rather than string token guesses") {
            try localWorld("backticks", source: """
            func helper() { typealias `Parent` = XCTestCase; class Legacy: `Parent` {} }
            """, expected: 2)
        }
    }

    private func localHelperCases() {
        test("unconsumed alias and namespace beside baseless helpers remain valid") {
            try localWorld("baseless", source: "func helper() { typealias Parent = XCTestCase; " +
                           "enum Local { typealias Parent = XCTestCase }; class Helper {} }", expected: 0)
        }
        test("unconsumed alias beside unindexed external ancestry remains valid model-only") {
            try localWorld("unindexed", source: """
            func helper() { typealias Parent = XCTestCase; class Helper: External.Base {} }
            """, expected: 0)
        }
        test("local Helper Plain refusal remains with and without an unused alias") {
            for (name, unused) in [("plain", ""), ("plain-unused", "typealias Parent = XCTestCase;")] {
                try localWorld(name, source: "class Plain {}\nfunc helper() { \(unused) class Helper: Plain {} }",
                               expected: 2)
            }
        }
        test("source-owned plain extension helper remains distinct from local binding") {
            try localWorld("extension-helper", source: """
            class Plain {}
            class Container {}
            extension Container { class Helper: Plain {} }
            """, expected: 0)
        }
        test("local direct SDK ancestry remains refused independently of alias provenance") {
            try localWorld("direct-sdk", source: """
            import class XCTest.XCTestCase
            func helper() { class Legacy: XCTestCase {} }
            """, expected: 2)
        }
        test("comments and raw string declarations are not lexical provenance") {
            try localWorld("strings", source: #"""
            func helper() {
                // typealias Parent = XCTestCase
                let text = #"typealias Parent = XCTestCase; class Fake: Parent {}"#
                class Helper: External.Base {}
            }
            """#, expected: 0)
        }
        test("a local class member body is not its inheritance lookup scope; unindexed model-only") {
            try localWorld("own-body", source: """
            func helper() {
                class Helper: Local.Parent { enum Local { typealias Parent = XCTestCase } }
            }
            """, expected: 0)
        }
        test("physically enclosing extension aliases are local consumption, not extension-target lookup") {
            try localWorld("lexical-extension", source: """
            class Container {}
            extension Container {
                typealias Parent = XCTestCase
                func helper() { class Legacy: Parent {} }
            }
            """, expected: 2)
        }
    }
}

extension FixtureTests {
    private struct AssociatedCase {
        let name: String
        let source: String
        let expected: Int
    }

    private func associatedOwnerCases() {
        associatedWitnessCases()
        associatedBoundaryCases()
        associatedForeignCases()
    }

    private func associatedWorld(
        _ name: String, first: String, second: String = "", expected: Int,
        diagnostic: String = "local source ancestry provenance"
    ) throws {
        let fixture = try world("associated-" + name, annotated: true)
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
        try require(fixture.run().enforcementSatisfied, "registered associated-owner control failed")
        try fixture.write("Sources/A.swift",
                          "@Suite(.productionAccessAudit) struct Example { @Test func body() {} }\n" + first)
        try fixture.write("Mac/B.swift", second)
        for mode in ["enforce", "inventory"] {
            let report = fixture.run(mode: mode)
            try report.encoded().write(to: fixture.root.appendingPathComponent(mode + "-result.json"))
            try require(report.exitCode == expected && report.analysisComplete == (expected == 0) &&
                        report.enforcementSatisfied == (expected == 0), "associated-owner outcome: \(name)")
            if expected == 2 {
                try require(report.diagnostics.filter {
                    $0.message.contains(diagnostic)
                }.count == 16, "wrong associated-owner refusal: \(name)")
            } else {
                try require(report.diagnostics.isEmpty, "unexpected associated-owner helper diagnostics")
            }
        }
    }

    private func associatedWitnessCases() {
        for (kind, parent) in [("sdk", "XCTestCase"), ("ordinary", "Plain")] {
            let header = "import class XCTest.XCTestCase\n" + (kind == "ordinary" ? "class Plain {}\n" : "")
            let method = "    func helper() {\n        class Legacy: Parent {}\n    }\n}\n"
            test("associated extension \(kind) matches the compiler-qualified diagnostic source") {
                try associatedWorld("extension-" + kind,
                    first: header + "class Container { typealias Parent = \(parent) }\n" +
                        "extension Container {\n" + method, expected: 2)
            }
            test("associated inherited \(kind) matches the compiler-qualified diagnostic source") {
                try associatedWorld("inherited-" + kind,
                    first: header + "class Base { typealias Parent = \(parent) }\n" +
                        "class Container: Base {\n" + method, expected: 2)
            }
        }
        test("associated unconsumed baseless helper preserves the qualified diagnostic source") {
            try associatedWorld("unconsumed-baseless", first:
                "import class XCTest.XCTestCase\nclass Base { typealias Parent = XCTestCase }\n" +
                "class Container: Base {}\nextension Container {\n    func helper() {\n" +
                "        class Legacy {}\n    }\n}\n", expected: 0)
        }
        test("associated unrelated owner cannot contaminate the qualified external helper control") {
            try associatedWorld("unrelated-owner-external", first:
                "import Foundation\nimport class XCTest.XCTestCase\n" +
                "class Unrelated { typealias NSObject = XCTestCase }\n" +
                "class Container {}\nextension Container {\n    func helper() {\n" +
                "        class Legacy: NSObject {}\n    }\n}\n", expected: 0)
        }
    }

    private func associatedBoundaryCases() {
        let method = "func helper() { class Legacy: Parent {} }"
        let cases: [AssociatedCase] = [
            .init(name: "other-extension", source: """
            class Container {}
            extension Container { typealias Parent = XCTestCase }
            extension Container { \(method) }
            """, expected: 2),
            .init(name: "inherited-extension", source: """
            class Base { typealias Parent = XCTestCase }
            class Container: Base {}
            extension Container { \(method) }
            """, expected: 2),
            .init(name: "function-formal", source: """
            class Container { typealias Parent = XCTestCase }
            extension Container { func helper<Parent>() { class Legacy: Parent.Member {} } }
            """, expected: 0),
            .init(name: "target-formal", source: """
            class Container<Parent> {}
            extension Container { func helper() { class Legacy: Parent.Member {} } }
            """, expected: 0),
            .init(name: "farther-formal", source: """
            class Base { typealias Parent = XCTestCase }
            enum Outer<Parent> { class Container: Base { \(method) } }
            """, expected: 2),
            .init(name: "local-baseless", source: """
            func outer() { class Container { func helper() { class Legacy: External.Parent {} } } }
            """, expected: 0),
            .init(name: "local-inherited-unmodeled", source: """
            func outer<Parent>() {
                class Base { typealias Parent = XCTestCase }
                class Container: Base { \(method) }
            }
            """, expected: 2),
            .init(name: "unresolved-owner", source: "extension Missing { \(method) }", expected: 2),
            .init(name: "cyclic-owner", source: """
            extension Container { \(method) }
            class Container: Base {}
            class Base: Container {}
            """, expected: 2),
            .init(name: "no-outward-owner", source: """
            enum Outer { typealias Parent = XCTestCase; class Inner {} }
            extension Outer.Inner { \(method) }
            """, expected: 0),
            .init(name: "global-fallback", source: """
            class Plain {}
            typealias Parent = Plain
            enum Outer { typealias Parent = XCTestCase; class Inner {} }
            extension Outer.Inner { \(method) }
            """, expected: 2)
        ]
        for item in cases {
            let name = item.name
            test("associated owner boundary \(name); source-model-only control") {
                // Global source binding still declines locally; do not broaden ordinary fallback.
                let diagnostic = name == "global-fallback" ? "unsupported shadowed/indeterminate XCTest ancestry" :
                    "local source ancestry provenance"
                try associatedWorld(name, first: item.source, expected: item.expected, diagnostic: diagnostic)
            }
        }
    }

    private func associatedForeignCases() {
        let method = "extension Container { func helper() { class Legacy: Parent {} } }"
        test("associated foreign private same-spelling owner proves no membership; model-only") {
            try associatedWorld("foreign", first: """
            private class Container {}
            extension Container { typealias Parent = XCTestCase }
            """, second: "private class Container {}\n" + method, expected: 0)
        }
        test("associated inaccessible actual-owner member is indeterminate; model-only") {
            try associatedWorld("inaccessible", first: """
            class Container {}
            extension Container { private typealias Parent = XCTestCase }
            """, second: method, expected: 2)
        }
        test("associated ambiguous extension target is indeterminate; model-only") {
            try associatedWorld("ambiguous", first: "class Container {}",
                                second: "class Container {}\n" + method, expected: 2)
        }
    }
}
#endif
