#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureTests {
    func erasedAncestryCases() {
        erasedIntermediateCases()
        erasedInitializerCases()
        erasedBindingCases()
        erasedOrdinaryCases()
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
#endif
