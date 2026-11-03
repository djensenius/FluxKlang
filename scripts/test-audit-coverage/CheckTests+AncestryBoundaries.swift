#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureTests {
    func ancestryBoundaryCases() {
        diagnosticBoundaryCases()
        getterBoundaryCases()
        compositionBoundaryCases()
        memberCacheBoundaryCases()
    }

    private func boundaryWorld(_ name: String, source: String, expected: Int, diagnostic: String = "XCTest") throws {
        let fixture = try world("ancestry-boundary-" + name, annotated: true)
        try fixture.register(fixture.run().derivedRegistrations)
        try require(fixture.run().enforcementSatisfied, "registered boundary control failed")
        try fixture.write("Sources/A.swift",
                          "@Suite(.productionAccessAudit) struct Example { @Test func body() {} }\n" + source)
        for mode in ["enforce", "inventory"] {
            let report = fixture.run(mode: mode)
            try report.encoded().write(to: fixture.root.appendingPathComponent(mode + "-result.json"))
            try require(report.exitCode == expected && report.analysisComplete == (expected == 0) &&
                        report.enforcementSatisfied == (expected == 0), "ancestry boundary outcome: \(name)")
            if expected == 0 {
                try require(report.diagnostics.isEmpty, "unexpected helper diagnostics: \(name)")
            } else {
                try require(report.diagnostics.contains {
                    $0.category == "model" && $0.message.contains(diagnostic)
                }, "missing model refusal: \(name)")
            }
        }
    }

    private func diagnosticBoundaryCases() {
        // Exact eight retained P1 witnesses; their positive static constraints
        // are historical evidence, not executed by this source-only fixture.
        let getterPrefix = "class Plain {}; typealias Parent = XCTestCase; struct Outer { "
        let sibling = " }; class Legacy: Parent {} }"
        let cases: [(String, String)] = [
            ("exact-property-getter-sdk",
             getterPrefix + "var value: Int { typealias Parent = Plain; return 0" + sibling),
            ("implicit-subscript-sdk",
             getterPrefix + "subscript(index: Int) -> Int { typealias Parent = Plain; return 0" + sibling),
            ("explicit-get-sdk",
             getterPrefix + "var value: Int { get { typealias Parent = Plain; return 0 }" + sibling),
            ("enclosing-member-ordinary",
             getterPrefix + "typealias Parent = Plain; var value: Int { return 0" + sibling),
            ("unconsumed-getter-baseless",
             getterPrefix + "var value: Int { typealias Parent = Plain; return 0 }; class Legacy {} }"),
            ("exact-consumed-composition-sdk",
             "protocol Marker {}; typealias Parent = XCTestCase & Marker; class Legacy: Parent {}"),
            ("consumed-composition-ordinary",
             "class Plain {}; protocol Marker {}; typealias Parent = Plain & Marker; class Legacy: Parent {}"),
            ("unconsumed-composition",
             "protocol Marker {}; typealias Parent = XCTestCase & Marker; class Legacy {}")
        ]
        let helpers = ["enclosing-member-ordinary", "unconsumed-getter-baseless", "unconsumed-composition"]
        for (name, source) in cases {
            test("retained P1 \(name) preserves bounded ancestry disposition") {
                try boundaryWorld(name, source: "import class XCTest.XCTestCase\n" + source + "\n",
                                  expected: helpers.contains(name) ? 0 : 2)
            }
        }
    }

    private func getterBoundaryCases() {
        for (name, body) in [
            ("property", "var value: Int"),
            ("subscript", "subscript(index: Int) -> Int")
        ] {
            test("implicit \(name) keeps internal alias consumption rejection-only; model-only") {
                try boundaryWorld(name + "-internal", source: """
                struct Outer {
                    \(body) { typealias Parent = Plain; class Legacy: (Parent) {}; return 0 }
                }
                """, expected: 2, diagnostic: "local source ancestry provenance")
            }
            test("implicit \(name) does not contaminate a sibling method; model-only") {
                try boundaryWorld(name + "-method", source: """
                struct Outer {
                    \(body) { typealias Parent = XCTestCase; return 0 }
                    func helper() { class Legacy: ExternalBase {} }
                }
                """, expected: 0)
            }
        }
        test("sibling implicit getters do not share declarations; unindexed model-only") {
            try boundaryWorld("getter-siblings", source: """
            struct Outer {
                var first: Int { typealias Parent = XCTestCase; return 0 }
                var second: Int { class Legacy: Parent {}; return 0 }
            }
            """, expected: 0)
        }
        test("subscript formal shadows enclosing alias without becoming resolution; model-only") {
            try boundaryWorld("subscript-formal", source: """
            struct Outer {
                typealias Parent = XCTestCase
                subscript<Parent>(index: Parent) -> Int { class Legacy: Parent {}; return 0 }
            }
            """, expected: 0)
        }
        test("getter alias is nearer than subscript formal; model-only") {
            try boundaryWorld("getter-before-formal", source: """
            struct Outer {
                subscript<Parent>(index: Parent) -> Int {
                    typealias Parent = Plain
                    class Legacy: Parent {}
                    return 0
                }
            }
            """, expected: 2, diagnostic: "local source ancestry provenance")
        }
        test("getter conditional containers retain local declarations in every variant; model-only") {
            try boundaryWorld("getter-conditional", source: """
            struct Outer {
                var value: Int {
                #if canImport(FluxKlangMac)
                    typealias Parent = XCTestCase
                #else
                    typealias Parent = Plain
                #endif
                    class Legacy: Parent {}
                    return 0
                }
            }
            """, expected: 2, diagnostic: "local source ancestry provenance")
        }
    }

    private func compositionBoundaryCases() {
        for (name, source) in [
            ("parenthesized", "typealias Parent = (Plain & Marker); class Legacy: Parent {}"),
            ("hop", "typealias Hidden = Plain & Marker; typealias Parent = (Hidden); class Legacy: Parent {}"),
            ("contextual", """
            class Base { typealias Parent = Plain & Marker }
            class Outer: Base { class Legacy: Parent {} }
            """)
        ] {
            test("consumed composition \(name) refuses unsupported initializer; model-only") {
                try boundaryWorld("composition-" + name, source: "class Plain {}; protocol Marker {}\n" + source,
                                  expected: 2)
            }
        }
        test("composition hops are refused across files and reversed order; model-only") {
            let sources = [
                ("A.swift", "class Plain {}; protocol Marker {}; typealias Hidden = Plain & Marker"),
                ("B.swift", "typealias Parent = (Hidden); class Legacy: Parent {}")
            ]
            for order in [sources, Array(sources.reversed())] {
                try rejects({ _ = try sourceReport(order) }, containing: "XCTest")
            }
        }
        test("direct class composition keeps prior raw disposition; model-only, not compiler qualification") {
            try boundaryWorld("direct-composition", source: """
            class Plain {}; protocol Marker {}; class Legacy: Plain & Marker {}
            """, expected: 0)
        }
    }

    private func memberCacheBoundaryCases() {
        let root = "class Base: ExternalBase { private typealias Result = (Int, Int); func testRoot() -> Result {} }"
        let inherited = "class Child: Base { func testInherited() -> Result {} }"
        test("completed root member hit cannot bypass inherited restrictions in either warm order; model-only") {
            for source in [root + "\n" + inherited, inherited + "\n" + root] {
                try rejects({ _ = try sourceReport([("A.swift", source)]) }, containing: "XCTest")
            }
        }
        test("completed same-file hit cannot establish a foreign consumer binding; model-only") {
            let sources = [
                ("A.swift", root),
                ("B.swift", "extension Base { func testForeign() -> Result {} }")
            ]
            for order in [sources, Array(sources.reversed())] {
                try rejects({ _ = try sourceReport(order) }, containing: "XCTest")
            }
        }
        test("ordinary inherited member hits still prove non-Void through unknown bases; model-only") {
            try boundaryWorld("ordinary-hit", source: """
            class Base: ExternalBase { typealias Result = (Int, Int) }
            class Child: Base {
                func testFirst() -> Result {}
                func testSecond() -> Result {}
            }
            """, expected: 0)
        }
        test("same-spelling foreign private owner cannot contaminate a completed local miss; model-only") {
            let sources = [
                ("A.swift", "private class Outer { typealias NSObject = XCTestCase }"),
                ("B.swift", "private class Outer { func helper() { class Local: NSObject {} } }")
            ]
            for order in [sources, Array(sources.reversed())] {
                try require(try sourceReport(order).exitCode == 0, "foreign owner contaminated miss")
            }
        }
        test("ambiguous actual members remain indeterminate at the first local consumer; model-only") {
            try boundaryWorld("ambiguous-members", source: """
            class Base { typealias Parent = Plain; typealias Parent = Other }
            class Outer: Base {
                func first() { class Local: Parent {} }
                func second() { class Local: Parent {} }
            }
            """, expected: 2, diagnostic: "local source ancestry provenance")
        }
        for (name, source) in [
            ("cycle", """
            class First: Second {
                func testOne() -> NSObject {}
                func testTwo() -> NSObject {}
            }
            class Second: First {}
            """),
            ("unresolved", "class First: ExternalBase { func testProbe() -> Int {} }")
        ] {
            test("repeated \(name) member queries never become cached absence; model-only") {
                let row = MatrixRow(target: "FixtureTests", module: "FixtureTests",
                                    platform: "macOS", configuration: "Debug")
                var inventory = SourceInventory(variant: SourceVariant(
                    matrix: row, macImport: false, modelsImport: false))
                try inventory.add(ParsedSource(path: "A.swift", text: source))
                let guarder = XCTestDiscoveryGuard(inventory, bindings: SourceExtensionOwnership(inventory))
                for _ in 0..<2 { try rejects({ try guarder.validate() }, containing: "ancestry") }
            }
        }
    }
}
#endif
