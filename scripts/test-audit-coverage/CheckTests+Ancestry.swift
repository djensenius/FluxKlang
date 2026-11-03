#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureTests {
    func erasedAncestryCases() {
        erasedIntermediateCases()
        erasedInitializerCases()
        erasedBindingCases()
        erasedOrdinaryCases()
        contextualAncestryCases()
        lookupAncestryCases()
    }

    private func erasedIntermediateCases() {
        let definitions = """
        import class XCTest.XCTestCase
        enum Names<T> { typealias Base = XCTestCase }
        typealias Hidden = Names<Int>.Base
        """
        test("erased generic alias follows its supported raw intermediate initializer") {
            try rejectLegacy("erased-exact", first: definitions + """

            typealias Parent<T> = Hidden
            class Legacy: Parent<Int> {}
            """)
        }
        test("parenthesized erased generic initializer cannot hide an intermediate hop") {
            try rejectLegacy("erased-parenthesized", first: definitions + """

            typealias Parent<T> = ((Hidden))
            class Legacy: Parent<Int> {}
            """)
        }
        test("cross-file erased generic alias hops remain order independent") {
            let second = "typealias Middle = Hidden\ntypealias Parent<T> = Middle\nclass Legacy: Parent<Int> {}"
            try rejectLegacy("erased-cross-file", first: definitions, second: second)
            for ordered in [[("A.swift", definitions), ("B.swift", second)],
                            [("B.swift", second), ("A.swift", definitions)]] {
                try rejects({ _ = try sourceReport(ordered) }, containing: "XCTest")
            }
        }
        test("raw generic initializers cannot erase bare qualified or indirectly known XCTest ancestry") {
            for (index, initializer) in ["XCTestCase", "XCTest.XCTestCase", "((XCTestCase))", "Hidden"].enumerated() {
                try rejectLegacy("erased-bare-\(index)", first: """
                import class XCTest.XCTestCase
                typealias Hidden = XCTestCase
                typealias Parent<T> = \(initializer)
                class Legacy: Parent<Int> {}
                """)
            }
        }
    }

    private func erasedInitializerCases() {
        test("unresolved generic initializer parameters cannot bind an unrelated global name") {
            // These are model controls, not compiler-proven XCTest inheritance witnesses.
            for (index, initializer) in ["T", "((T))", "T.Base", "Missing", "External<T>"].enumerated() {
                try rejectLegacy("erased-parameter-\(index)", first: """
                class T { class Base {} }
                typealias Parent<T> = \(initializer)
                class Legacy: Parent<Int> {}
                """)
            }
            try rejectLegacy("erased-parameter-xctest", first: """
            class XCTestCase {}
            typealias Parent<XCTestCase> = XCTestCase
            class Legacy: Parent<Int> {}
            """)
            try rejectLegacy("erased-parameter-chain", first: """
            class U {}
            typealias Middle<U> = U
            typealias Parent<T> = Middle<T>
            class Legacy: Parent<Int> {}
            """)
        }
        test("unmodeled raw generic initializer syntax is refused rather than skipped") {
            for (index, initializer) in ["(T) -> T", "[T]", "T?", "(T, T)"].enumerated() {
                try rejectLegacy("erased-syntax-\(index)", first: """
                typealias Parent<T> = \(initializer)
                class Legacy: Parent<Int> {}
                """)
            }
        }
        test("cyclic ambiguous and inaccessible raw generic bindings cannot satisfy empty class enforcement") {
            for (index, declarations) in [
                "typealias Hidden = Parent<Int>",
                "class Plain {}; typealias Hidden = Plain; typealias Hidden = Missing"
            ].enumerated() {
                try rejectLegacy("erased-uncertain-\(index)", first: declarations + """

                typealias Parent<T> = Hidden
                class Legacy: Parent<Int> {}
                """)
            }
            try rejectLegacy("erased-private", first: "class Plain {}\nprivate typealias Hidden = Plain",
                             second: "typealias Parent<T> = Hidden\nclass Legacy: Parent<Int> {}")
        }
    }

    private func erasedBindingCases() {
        test("raw generic initializer follows the nearer declaration rather than an ordinary global alias") {
            try rejectLegacy("erased-nearer-xctest", first: """
            import class XCTest.XCTestCase
            class Plain {}
            typealias Hidden = Plain
            enum Outer {
                typealias Hidden = XCTestCase
                typealias Parent<T> = Hidden
                class Legacy: Parent<Int> {}
            }
            """)
        }
        test("raw generic initializer bindings preserve consistent conditional variants") {
            let definitions = """
            class Plain {}
            #if canImport(FluxKlangMac) && canImport(FoundationModels)
            typealias Hidden = XCTestCase
            #else
            typealias Hidden = Plain
            #endif
            """
            let usage = "typealias Parent<T> = Hidden\nclass Legacy: Parent<Int> {}"
            for mac in [false, true] {
                for models in [false, true] {
                    for sources in [[("A.swift", definitions), ("B.swift", usage)],
                                    [("B.swift", usage), ("A.swift", definitions)]] {
                        if mac && models {
                            try rejects({
                                _ = try sourceReport(sources, macImport: mac, modelsImport: models)
                            }, containing: "XCTest")
                        } else {
                            let report = try sourceReport(sources, macImport: mac, modelsImport: models)
                            try require(report.exitCode == 0, "ordinary erased initializer variant changed")
                        }
                    }
                }
            }
        }
    }

    private func erasedOrdinaryCases() {
        test("ordinary raw generic aliases and nearer ordinary bindings remain valid empty helpers") {
            for (index, source) in [
                "class Plain {}\ntypealias Hidden = Plain\ntypealias Parent<T> = Hidden\nclass Helper: Parent<Int> {}",
                """
                import class XCTest.XCTestCase
                class Plain {}
                typealias Hidden = XCTestCase
                enum Outer {
                    typealias Hidden = Plain
                    typealias Parent<T> = Hidden
                    class Helper: Parent<Int> {}
                }
                """,
                "class XCTestCase {}\ntypealias Parent<T> = XCTestCase\nclass Helper: Parent<Int> {}",
                "class Plain<T> {}\ntypealias Parent<T> = Plain<T>\nclass Helper: Parent<Int> {}",
                """
                class Plain<T> {}
                typealias Middle<T> = Plain<T>
                typealias Parent<T> = Middle<T>
                class Helper: Parent<Int> {}
                """
            ].enumerated() {
                let fixture = try world("erased-ordinary-\(index)", annotated: true)
                try fixture.register(fixture.run().derivedRegistrations)
                try fixture.write("Sources/A.swift",
                                  "@Suite(.productionAccessAudit) struct Example { @Test func body() {} }\n" + source)
                for mode in ["enforce", "inventory"] {
                    try require(fixture.run(mode: mode).enforcementSatisfied, "ordinary generic alias over-rejected")
                }
            }
        }
        test("rejection-only traversal never establishes ordinary lineage for a generic test-shaped helper") {
            try rejectLegacy("erased-no-ordinary-proof", first: """
            class Plain {}
            typealias Hidden = Plain
            typealias Parent<T> = Hidden
            class Helper: Parent<Int> { func testUtility() {} }
            """)
        }
        test("unused generic helper aliases are not ancestry obligations") {
            let report = try sourceReport([("A.swift", """
            typealias Callback<T> = (T) -> T
            typealias Values<T> = [T]
            @Suite(.productionAccessAudit) struct Example { @Test func body() {} }
            """)])
            try require(report.enforcementSatisfied, "non-ancestry generic helper aliases were rejected")
        }
    }
}

extension FixtureTests {
    func contextualAncestryCases() {
        moduleAncestryCases()
        inheritedAncestryCases()
        enclosingOrdinaryCases()
        enclosingUncertainCases()
    }

    private func moduleAncestry(_ declaration: String) -> String {
        "#if os(iOS)\n" + declaration.replacingOccurrences(of: "MODULE", with: "FluxKlangTests") +
            "\n#else\n" + declaration.replacingOccurrences(of: "MODULE", with: "FluxKlangMacTests") + "\n#endif"
    }

    private func moduleAncestryCases() {
        test("current module qualifiers cannot hide direct or aliased XCTest ancestry") {
            for (index, declaration) in ["class Legacy: MODULE.Base {}",
                                         "typealias Hop = MODULE.Base\nclass Legacy: Hop {}"].enumerated() {
                try rejectLegacy("r10-module-\(index)", first:
                    "import XCTest\ntypealias Base = XCTestCase\n" + moduleAncestry(declaration))
            }
        }
        test("module-qualified generic and parenthesized ancestry stays structural") {
            for (index, declaration) in [
                "enum Names<T> { typealias Base = XCTestCase }\nclass Legacy: MODULE.Names<Int>.Base {}",
                "typealias Base = XCTestCase\ntypealias Hop = ((MODULE.Base))\nclass Legacy: Hop {}",
                "typealias Base = XCTestCase\ntypealias Hop<T> = MODULE.Base\nclass Legacy: Hop<Int> {}"
            ].enumerated() {
                try rejectLegacy("r10-module-raw-\(index)", first: "import XCTest\n" + moduleAncestry(declaration))
            }
        }
        test("module alias hops crossing files cannot satisfy enforcement") {
            try rejectLegacy("r10-module-cross", first: "import XCTest\ntypealias Base = XCTestCase\n" +
                             moduleAncestry("typealias Hop = MODULE.Base"),
                             second: "class Legacy: Hop {}")
        }
        test("unshadowed current-module ordinary ancestry is refused rather than semantically stripped") {
            try rejectLegacy("r10-module-ordinary", first: "class Plain {}\ntypealias Base = Plain\n" +
                             moduleAncestry("class Helper: MODULE.Base {}"))
        }
        test("lexical source namespaces shadow module spelling without stripping") {
            let namespaces = "enum FluxKlangTests { class Base {} }\nenum FluxKlangMacTests { class Base {} }\n"
            let helper = moduleAncestry("class Helper: MODULE.Base {}")
            for (index, declaration) in [
                namespaces + helper,
                "enum Outer {\n" + namespaces + helper + "\n}",
                "class Holder {\n" + namespaces + "\n}\nclass Outer: Holder {\n" + helper + "\n}"
            ].enumerated() {
                try ordinaryEnclosing("r10-module-shadow-\(index)",
                                      source: "import XCTest\ntypealias Base = XCTestCase\n" + declaration)
            }
        }
    }

    private func inheritedAncestryCases() {
        let definitions = "import XCTest\nclass Base { typealias Parent = XCTestCase }\n"
        test("nested class cannot inherit a hidden enclosing XCTest alias") {
            try rejectLegacy("r10-inherited-nested", first: definitions +
                             "class Outer: Base { class Legacy: Parent {} }")
        }
        test("extension class cannot inherit a hidden enclosing XCTest alias") {
            try rejectLegacy("r10-inherited-extension", first: definitions +
                             "class Outer: Base {}\nextension Outer { class Legacy: Parent {} }")
        }
        test("inherited alias hops cross files and declaration order") {
            let first = definitions + "class Middle: Base {}\nclass Outer: Middle {}"
            let second = "extension Outer { typealias Hop = Parent; class Legacy: Hop {} }"
            try rejectLegacy("r10-inherited-cross", first: first, second: second)
            for files in [[("A.swift", first), ("B.swift", second)],
                          [("B.swift", second), ("A.swift", first)]] {
                try rejects({ _ = try sourceReport(files) }, containing: "XCTest")
            }
            try rejectLegacy("r10-inherited-dotted", first: """
            import XCTest
            class Base { enum Names { typealias Parent = XCTestCase } }
            class Outer: Base { class Legacy: Names.Parent {} }
            """)
        }
    }

    private func ordinaryEnclosing(_ name: String, source: String, second: String = "") throws {
        let fixture = try world(name, annotated: true)
        try fixture.register(fixture.run().derivedRegistrations)
        try fixture.write("Sources/A.swift",
                          "@Suite(.productionAccessAudit) struct Example { @Test func body() {} }\n" + source)
        if !second.isEmpty { try fixture.write("Mac/B.swift", second) }
        for mode in ["enforce", "inventory"] {
            try require(fixture.run(mode: mode).enforcementSatisfied, "ordinary enclosing ancestry over-rejected")
        }
    }

    private func enclosingOrdinaryCases() {
        test("ordinary inherited and nearer source aliases remain empty helpers") {
            for (index, source) in [
                """
                class Plain {}
                class Base { typealias Parent = Plain }
                class Outer: Base { class Helper: Parent {} }
                extension Outer { class ExtendedHelper: Parent {} }
                """,
                """
                import XCTest
                class Plain {}
                class Base { typealias Parent = XCTestCase }
                class Outer: Base { typealias Parent = Plain; class Helper: Parent {} }
                """,
                """
                import XCTest
                class Plain {}
                class Base { typealias Parent = XCTestCase }
                class Outer: Base {}
                extension Outer { typealias Parent = Plain; class Helper: Parent {} }
                """,
                """
                import XCTest
                class Plain {}
                typealias Parent = XCTestCase
                class Base { typealias Parent = Plain }
                class Outer: Base { class Helper: Parent {} }
                """
            ].enumerated() { try ordinaryEnclosing("r10-ordinary-\(index)", source: source) }
            try ordinaryEnclosing(
                "r10-ordinary-cross",
                source: "class Plain {}\nclass Base { typealias Parent = Plain }\nclass Outer: Base {}",
                second: "extension Outer { typealias Hop = Parent; class Helper: Hop {} }")
        }
        test("ordinary generic enclosing helpers and inherited dotted members remain valid") {
            try ordinaryEnclosing("r10-ordinary-generic", source:
                "class Plain {}\nstruct Box<T> { class Helper: Plain {} }\nclass Holder<T> { class Helper: Plain {} }")
            try ordinaryEnclosing("r10-ordinary-dotted", source: """
            class Base { enum Names { class Parent {} } }
            class Outer: Base { class Helper: Names.Parent {} }
            """)
        }
        test("enclosing rejection checks never establish ordinary lineage for test-shaped helpers") {
            try rejectLegacy("r10-no-ordinary-proof", first: """
            class Plain {}
            class Base { typealias Parent = Plain }
            class Outer: Base { class Helper: Parent { func testUtility() {} } }
            """)
        }
    }

    private func enclosingUncertainCases() {
        test("unknown restricted generic and cyclic enclosing bindings fail closed") {
            // Unsupported/access/cyclic/formal-parameter examples are model controls, not inheritance proofs.
            for (index, source) in [
                "class Outer: Missing { class Legacy: Parent {} }",
                "class Base<T> { typealias Parent = XCTestCase }\nclass Outer: Base<Int> { class Legacy: Parent {} }",
                "class Base: Outer {}\nclass Outer: Base { class Legacy: Parent {} }",
                """
                class T {}
                class Base {}
                class Outer: Base { typealias Parent<T> = T; class Legacy: Parent<Int> {} }
                """,
                """
                class Base { typealias Parent<T> = XCTestCase }
                class Outer: Base { class Legacy: Parent<Int> {} }
                """,
                """
                class Plain {}
                typealias Parent = Plain
                class Outer: Missing { class Legacy: Parent {} }
                """,
                """
                import XCTest
                class Plain {}
                typealias Parent = Plain
                class Base { typealias Parent = XCTestCase }
                class Outer: Base { class Legacy: Parent {} }
                """,
                """
                class Base {}
                class Outer: Base { enum Names<T> { class Parent {} }; class Legacy: Names.Parent {} }
                """
            ].enumerated() { try rejectLegacy("r10-uncertain-\(index)", first: source) }
            try rejectLegacy("r10-private", first: "class Plain {}\nclass Base { private typealias Parent = Plain }",
                             second: "class Outer: Base { class Legacy: Parent {} }")
        }
        test("enclosing ancestry binding respects conditional variants and order") {
            let first = """
            class Plain {}
            class Base {
                #if canImport(FoundationModels)
                typealias Parent = XCTestCase
                #else
                typealias Parent = Plain
                #endif
            }
            """
            let second = "class Outer: Base { class Legacy: Parent {} }"
            for models in [false, true] {
                for sources in [[("A.swift", first), ("B.swift", second)],
                                [("B.swift", second), ("A.swift", first)]] {
                    if models {
                        try rejects({ _ = try sourceReport(sources, modelsImport: models) }, containing: "XCTest")
                    } else {
                        let report = try sourceReport(sources, modelsImport: models)
                        try require(report.exitCode == 0, "ordinary inherited conditional alias changed")
                    }
                }
            }
        }
    }
}

extension FixtureTests {
    private func lookupAncestryCases() {
        let ordinary = "class Plain {}\nclass XCTestCase: Plain {}\n"
        test("source XCTestCase class binds before SDK terminal spelling") {
            try ordinaryEnclosing("r11-direct", source: ordinary + "class Helper: XCTestCase {}")
        }
        test("nongeneric alias to source XCTestCase retains ordinary lineage") {
            try ordinaryEnclosing("r11-alias", source: ordinary +
                                  "typealias Parent = XCTestCase\nclass Helper: Parent {}")
        }
        test("source XCTest namespace binds its ordinary XCTestCase member") {
            try ordinaryEnclosing("r11-namespace", source:
                "class Plain {}\nenum XCTest { class XCTestCase: Plain {} }\nclass Helper: XCTest.XCTestCase {}")
        }
        test("source alias named XCTestCase binds before imported terminal spelling") {
            try ordinaryEnclosing("r11-alias-name", source:
                "import XCTest\nclass Plain {}\ntypealias XCTestCase = Plain\nclass Helper: XCTestCase {}")
        }
        test("nearer and inherited source terminal shadows remain empty ordinary helpers") {
            try ordinaryEnclosing("r11-nearer", source:
                "import XCTest\nenum Outer { class XCTestCase {}; class Helper: XCTestCase {} }")
            try ordinaryEnclosing("r11-inherited", source:
                "class Plain {}\nclass Base { class XCTestCase: Plain {} }\n" +
                "class Outer: Base { class Helper: XCTestCase {} }")
        }
        test("source bindings that actually lead to SDK XCTest remain refused") {
            try rejectLegacy("r11-sdk-source", first: """
            import XCTest
            typealias SDKCase = XCTestCase
            enum XCTest { typealias XCTestCase = SDKCase }
            class Legacy: XCTest.XCTestCase {}
            """)
            try rejectLegacy("r11-sdk-enclosing", first:
                "import XCTest\nclass Base {}\nclass Outer: Base { class Legacy: XCTestCase {} }")
        }
        test("terminal shadow ambiguity access and cycles never establish ordinary lineage") {
            // Cyclic and duplicate declarations are conservative model controls, not compiler witnesses.
            try rejectLegacy("r11-cycle", first:
                "typealias XCTestCase = Parent\ntypealias Parent = XCTestCase\nclass Helper: Parent {}")
            try rejectLegacy("r11-ambiguous", first:
                "class XCTestCase {}\nclass XCTestCase {}\nclass Helper: XCTestCase {}")
            try rejectLegacy("r11-private", first: "private class XCTestCase {}",
                             second: "class Helper: XCTestCase {}")
        }
        test("shared completed unknown ancestry cannot become an ordinary proof") {
            try rejectLegacy("r11-shared-unknown", first:
                "class Shared: Missing {}\nclass Left: Shared {}\nclass Right: Shared { func testUtility() {} }")
            try rejectLegacy("r11-inherited-no-proof", first:
                "class Base { class XCTestCase {} }\nclass Outer: Base { " +
                "class Helper: XCTestCase { func testUtility() {} } }")
        }
        test("bounded ordinary chains preserve shared ancestry and reversed declaration order") {
            for count in [16, 32, 64] {
                let chain = ["class C0 {}"] + (1..<count).map { "class C\($0): C\($0 - 1) {}" }
                let shared = "typealias Parent = C\(count - 1)\nclass Left: Parent {}\n" +
                    "class Right: Parent { func testUtility() {} }"
                for declarations in [chain, Array(chain.reversed())] {
                    let report = try sourceReport([("A.swift", declarations.joined(separator: "\n")),
                                                   ("B.swift", shared)])
                    try require(report.enforcementSatisfied, "bounded ordinary chain changed")
                }
            }
        }
        test("binding and ancestry caches stay isolated across variants files and inventories") {
            let definitions = """
            import XCTest
            #if canImport(FoundationModels)
            class XCTestCase {}
            #endif
            typealias Parent = XCTestCase
            """
            let usage = "class Helper: Parent {}"
            for models in [true, false, true] {
                for files in [[("A.swift", definitions), ("B.swift", usage)],
                              [("B.swift", usage), ("A.swift", definitions)]] {
                    if models {
                        let report = try sourceReport(files, modelsImport: models)
                        try require(report.enforcementSatisfied, "source shadow cache leaked between inventories")
                    } else {
                        try rejects({ _ = try sourceReport(files, modelsImport: models) }, containing: "XCTest")
                    }
                }
            }
        }
        test("cyclic provisional lineage cannot be memoized as a completed ancestry proof") {
            // These cycles intentionally exercise the source model, not compilable inheritance.
            let cycle = "class Plain {}\nclass Early: Plain {}\ntypealias A = B\ntypealias B = A\n"
            try rejectLegacy("r11-lineage-cycle-extension", first: cycle +
                "class Helper: A {}\nextension Helper { func testUtility() {} }")
            try rejectLegacy("r11-lineage-cycle-erased", first: cycle +
                "typealias Parent<T> = A\nclass Helper: Parent<Int> {}")
        }
    }
}
#endif
