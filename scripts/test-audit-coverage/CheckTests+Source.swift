#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureTests {
    func sourceReport(
        _ sources: [(String, String)], configuration: String = "Debug",
        platform: String = "iOS", macImport: Bool = false, modelsImport: Bool = false
    ) throws -> AuditReport {
        let matrix = MatrixRow(target: "FixtureTests", module: "FixtureTests",
                               platform: platform, configuration: configuration)
        var inventory = SourceInventory(variant: SourceVariant(
            matrix: matrix, macImport: macImport, modelsImport: modelsImport))
        for (path, text) in sources { try inventory.add(ParsedSource(path: path, text: text)) }
        let result = try SourceOwnership(inventory).analyze()
        var report = AuditReport(mode: "enforce")
        report.ownership = result.rows
        report.diagnostics = result.diagnostics
        report.finish()
        return report
    }

    func sourceCases() {
        conditionCases()
        ownershipCases()
        annotationCases()
        syntaxCases()
        u1Cases()
        legacyDiscoveryCases()
        observationCases()
    }

    func conditionCases() {
        test("mutually exclusive declarations are not overlapping owners") {
            let source = """
            #if DEBUG
            @Suite(.productionAccessAudit) struct Root { @Test func debug() {} }
            #else
            @Suite(.productionAccessAudit) struct Root { @Test func release() {} }
            #endif
            """
            for config in ["Debug", "Release"] {
                let report = try sourceReport([("A.swift", source)], configuration: config)
                try require(report.exitCode == 0 && report.ownership.count == 1, "exclusive roots failed")
                try require(report.ownership[0].tests[0].name.hasPrefix(config.lowercased()), "wrong active branch")
            }
        }
        test("overlapping conditional roots fail") {
            let source = """
            #if DEBUG
            struct Root { @Test func first() {} }
            #endif
            #if true
            struct Root { @Test func second() {} }
            #endif
            """
            try rejects({ _ = try sourceReport([("A.swift", source)]) }, containing: "ambiguous")
        }
        test("consistent symbolic canImport assignments across files") {
            let nominal = """
            #if canImport(FluxKlangMac)
            @Suite(.productionAccessAudit) struct MacRoot {}
            #else
            @Suite(.productionAccessAudit) struct OtherRoot {}
            #endif
            """
            let extended = """
            #if canImport(FluxKlangMac)
            extension MacRoot { @Test func body() {} }
            #else
            extension OtherRoot { @Test func body() {} }
            #endif
            #if canImport(FoundationModels)
            @Suite(.productionAccessAudit) struct ModelsRoot {}
            #endif
            """
            for mac in [false, true] {
                for models in [false, true] {
                    let report = try sourceReport([("A.swift", nominal), ("B.swift", extended)],
                                                  macImport: mac, modelsImport: models)
                    try require(report.exitCode == 0 && report.ownership.count == (models ? 2 : 1),
                                "inconsistent canImport variant")
                    try require(report.ownership.contains {
                        $0.registration.name == (mac ? "MacRoot" : "OtherRoot") && $0.tests.count == 1
                    }, "guessed availability or wrong ownership")
                }
            }
        }
        test("Boolean precedence parentheses negation os and elseif") {
            let source = """
            #if false || (DEBUG && os(iOS) && !canImport(FoundationModels))
            @Suite(.productionAccessAudit) struct IOS {}
            #elseif !DEBUG || os(macOS)
            @Suite(.productionAccessAudit) struct Other {}
            #endif
            """
            let ios = try sourceReport([("A.swift", source)])
            let mac = try sourceReport([("A.swift", source)], platform: "macOS")
            try require(ios.ownership[0].registration.name == "IOS", "condition precedence")
            try require(mac.ownership[0].registration.name == "Other", "elseif/os condition")
        }
        test("unsupported conditions fail even in inactive branches") {
            for condition in ["swift(>=6)", "compiler(>=6)", "targetEnvironment(simulator)", "FEATURE",
                              "canImport(Other)", "os(tvOS)", "DEBUG == true", "canImport(FluxKlangMac, _version: 1)"] {
                let source = "#if false\n#if \(condition)\nstruct Helper {}\n#endif\n#endif"
                try rejects { _ = try sourceReport([("A.swift", source)]) }
            }
        }
        test("supported conditional imports remain verbatim") {
            let source = """
            import Testing
            #if canImport(FluxKlangMac)
            @testable import FluxKlangMac
            #else
            @testable import FluxKlang
            #endif
            @Suite(.productionAccessAudit) struct Root {}
            """
            let parsed = try ParsedSource(path: "Actual.swift", text: source)
            try require(parsed.tree.description == source, "source imports rewritten")
        }
    }

    func ownershipCases() {
        test("empty suites and implicit outermost owners are obligations") {
            let report = try sourceReport([("HelperNamed.swift", """
            @Suite struct Empty {}
            struct Outer { @Suite struct Inner {} }
            """)])
            try require(report.exitCode == 1 && report.ownership.count == 2, "empty suite missed")
            try require(Set(report.ownership.map { $0.registration.name }) == ["Empty", "Outer"], "wrong root")
        }
        test("multiple roots in one file have no filename association") {
            let report = try sourceReport([("Unrelated.swift", """
            @Suite(.productionAccessAudit) struct First { @Test func one() {} }
            struct Second { @Test func two() {} }
            struct Helper {}
            """)])
            try require(report.ownership.count == 2 && report.ownership.filter(\.annotationSatisfied).count == 1,
                        "multiple roots/file exemption")
        }
        test("dotted cross-file extension ownership is order independent") {
            let sources = [
                ("Z.swift", "@Suite(.productionAccessAudit) struct Root { struct Nested {} }"),
                ("A.swift", "extension Root.Nested { @Test func crossFile() {} }"),
                ("B.swift", "extension Root { struct More { @Test func another() {} } }")
            ]
            let forward = try sourceReport(sources)
            let reverse = try sourceReport(Array(sources.reversed()))
            try require(forward.exitCode == 0 && forward.ownership[0].tests.count == 2, "dotted owner unresolved")
            try require(try forward.encoded() == reverse.encoded(), "declaration-order dependence")
        }
        test("unresolved owners aliases and suffix matches fail closed") {
            for sources in [
                [("A.swift", "extension Missing { @Test func body() {} }")],
                [("A.swift", "typealias Alias = Other\nextension Alias { @Test func body() {} }")],
                [("A.swift", "struct Root { struct Inner {} }\nextension Inner { @Test func body() {} }")]
            ] {
                try rejects({ _ = try sourceReport(sources) }, containing: "unresolved")
            }
        }
        test("private owners remain file scoped; unresolved private extension is not first matched") {
            let sources = [
                ("A.swift", "@Suite(.productionAccessAudit) private struct Same { @Test func first() {} }"),
                ("B.swift", "@Suite(.productionAccessAudit) private struct Same { @Test func second() {} }")
            ]
            let report = try sourceReport(sources)
            try require(report.exitCode == 0 && report.ownership.count == 2, "file-private roots conflated")
            try rejects({
                _ = try sourceReport(sources + [("C.swift", "extension Same { @Test func ambiguous() {} }")])
            }, containing: "ambiguous")
        }
        test("genuine overlapping visible owners fail") {
            try rejects({
                _ = try sourceReport([("A.swift", "struct Same {}"),
                                      ("B.swift", "struct Same { @Test func body() {} }")])
            }, containing: "ambiguous")
        }
        test("nested declarations in extensions cannot expose a private outer root across files") {
            let sources = [("A.swift", "private struct Root {}\nextension Root { struct Nested {} }"),
                           ("B.swift", "extension Root.Nested { @Test func body() {} }")]
            try rejects({ _ = try sourceReport(sources) }, containing: "unresolved")
            try rejects({
                _ = try sourceReport([sources[0], ("B.swift", """
                private struct Root {}
                extension Root.Nested { @Test func body() {} }
                """)])
            }, containing: "private")
        }
        declarationContextCases()
    }

    func declarationContextCases() {
        test("generic inherited constrained specialized and local test contexts fail") {
            for source in [
                "struct Generic<T> { @Test func body() {} }",
                "class Base {}\nclass Child: Base { @Test func body() {} }",
                "struct Root {}\nextension Root where Self: Equatable { @Test func body() {} }",
                "struct Root<T> {}\nextension Root<Int> { @Test func body() {} }",
                "func helper() { @Test func local() {} }",
                "let value = { struct Local { @Test func local() {} } }",
                "struct Root { @Test func generic<T>(value: T) {} }",
                "@Test func opaque(_ value: some Equatable) {}",
                "@Suite(.enabled(if: { @Test func local() {}; return true }())) struct Root {}",
                "protocol Requirement { @Test func body() }"
            ] {
                try rejects { _ = try sourceReport([("A.swift", source)]) }
            }
        }
        test("ordinary generic and non-test constrained external helpers remain supported") {
            let report = try sourceReport([("A.swift", """
            struct Helper<T>: Sendable where T: Sendable { func use(_ value: T) {} }
            extension Testing.Trait where Self == ProductionAccessScope {
                static var productionAccessAudit: Self { Self() }
            }
            extension Trait where Self == ProductionAccessScope {
                static var productionAccessAudit: Self { Self() }
            }
            @Suite(.productionAccessAudit) struct Root { @Test func body() {} }
            """)])
            try require(report.exitCode == 0 && report.ownership.count == 1, "helper improperly obligated")
        }
        test("free overload signatures are distinct source identities") {
            let report = try sourceReport([("A.swift", """
            @Test(.productionAccessAudit, arguments: [1]) func overloaded(_ value: Int) {}
            @Testing.Test(.productionAccessAudit, arguments: ["x"]) func overloaded(_ value: String) async throws {}
            """)])
            try require(report.exitCode == 0 && Set(report.derivedRegistrations.map(\.name)).count == 2,
                        "free overloads collapsed")
            try require(report.ownership.allSatisfy { $0.registration.kind == "freeTest" }, "free tests misowned")
        }
    }

    func annotationCases() {
        test("qualified Testing macros preserve standard traits disabled and parameterized obligations") {
            let report = try sourceReport([("A.swift", """
            @Testing.Suite(.productionAccessAudit, .serialized, .timeLimit(.minutes(1)), .disabled("disabled"))
            struct Root {
                @Testing.Test(.enabled(if: false), arguments: [1, 2], [false, true])
                func disabledParameterized(_ value: Int, _ flag: Bool) {}
                @Test(.timeLimit(.minutes(2))) func limited() {}
            }
            """)])
            try require(report.exitCode == 0 && report.ownership[0].tests.count == 2, "trait/obligation loss")
        }
        test("noncanonical calls explicit bases constructors wrappers aliases and labels cannot substitute") {
            for trait in [".productionAccessAudit()", "Trait.productionAccessAudit",
                          "ProductionAccessScope()", "wrap(.productionAccessAudit)",
                          "ProductionAccessScope(audit: privateAudit, runID: nil, submit: sink)",
                          "audit: .productionAccessAudit"] {
                let report = try sourceReport([("A.swift", "@Suite(\(trait)) struct Root {}")])
                try require(report.exitCode == 1 && !report.ownership[0].annotationSatisfied,
                            "noncanonical substitute accepted: \(trait)")
            }
            for trait in ["auditAlias", ".unknown", "Unknown()", "wrap(.serialized)"] {
                let report = try sourceReport([("A.swift", "@Suite(\(trait)) struct Root {}")])
                try require(report.exitCode == 2, "opaque auxiliary silently ignored: \(trait)")
            }
        }
        test("misplaced nested member extension and duplicate annotations") {
            for source in [
                "@Suite(.productionAccessAudit, .productionAccessAudit) struct Root {}",
                "@Suite(.productionAccessAudit) @Suite struct Root {}",
                "@Suite(.productionAccessAudit) struct Root { @Test(.productionAccessAudit) func body() {} }",
                "@Suite(.productionAccessAudit) struct Root { @Suite(.productionAccessAudit) struct Inner {} }",
                "struct Root {}\n@Suite(.productionAccessAudit) extension Root { @Test func body() {} }",
                "@Suite(.productionAccessAudit) @Test struct Root {}",
                "@Test(.productionAccessAudit) let notAFunction = 0"
            ] {
                let report = try sourceReport([("A.swift", source)])
                try require(report.exitCode == 1, "misplaced/duplicate annotation accepted")
            }
        }
        test("audit hidden in standard payload or parameter value fails") {
            for source in [
                "@Suite(.productionAccessAudit, .enabled(if: wrap(.productionAccessAudit))) struct Root {}",
                "@Test(.productionAccessAudit, arguments: [.productionAccessAudit]) func free(_ value: Int) {}"
            ] {
                let report = try sourceReport([("A.swift", source)])
                try require(report.exitCode == 1, "hidden audit ignored")
            }
        }
        test("unknown declaration macros and conflicting qualifications fail") {
            for source in ["@Other.Suite struct Root {}", "@Other.Test func body() {}",
                           "@WrappedTests struct Root {}", "#generateTests", "macro Suite() = #externalMacro()"] {
                try rejects { _ = try sourceReport([("A.swift", source)]) }
            }
        }
        test("SuiteExitProbe is auxiliary, never canonical production registration") {
            let missing = try sourceReport([("A.swift", "@Suite(SuiteExitProbe()) struct Root {}")])
            let adopted = try sourceReport([
                ("A.swift", "@Suite(SuiteExitProbe(), .productionAccessAudit) struct Root {}")
            ])
            try require(missing.exitCode == 1 && adopted.exitCode == 0, "reviewed auxiliary grammar incorrect")
            let injected = try sourceReport([
                ("A.swift", "@Suite(SuiteExitProbe(injected: true), .productionAccessAudit) struct Root {}")
            ])
            try require(injected.exitCode == 2, "opaque constructor expansion accepted")
        }
    }

    func syntaxCases() {
        test("syntax recovery malformed comments and missing tokens reject") {
            for source in ["struct Broken {", "@Test func test( {}", "/* unterminated",
                           "#if DEBUG\nstruct Root {}", "struct { @Test func body() {} }"] {
                try rejects({ _ = try sourceReport([("A.swift", source)]) }, containing: "syntax")
            }
        }
        test("raw strings comments and backticks are structural not textual matches") {
            let source = #"""
            // @Suite(.productionAccessAudit) struct Fake {}
            /* @Test func fake() {} */
            let text = #"@Suite(.productionAccessAudit) struct Fake { @Test func fake() {} }"#
            @Suite(.productionAccessAudit) struct `class` {
                @Test func `switch`() { let ignored = #"productionAccessAudit"# }
            }
            """#
            let report = try sourceReport([("A.swift", source)])
            try require(report.exitCode == 0 && report.ownership.count == 1 &&
                        report.ownership[0].registration.name == "class", "lexical false positive/backtick failure")
        }
        test("display string cannot count as annotation and interpolation cannot hide one") {
            let display = try sourceReport([
                ("A.swift", ##"@Suite(#".productionAccessAudit"#) struct Root {}"##)
            ])
            try require(display.exitCode == 1, "raw display string counted as annotation")
            let interpolation = try sourceReport([
                ("A.swift", #"@Suite("\(wrap(.productionAccessAudit))") struct Root {}"#)
            ])
            try require(interpolation.exitCode == 1, "interpolated audit hidden")
        }
    }

    func u1Cases() {
        test("actual frozen U1 sources preserve imports helpers two roots and auxiliary constructor") {
            var sources: [(String, String)] = []
            for name in ["ProductionAccessScope.swift", "ProductionAccessScopeTests.swift"] {
                let data = try Data(contentsOf: u1Root.appendingPathComponent(name))
                guard let text = String(data: data, encoding: .utf8) else { throw AuditFailure("U1 fixture UTF8") }
                sources.append(("FluxKlangTests/" + name, text))
                print("U1_SOURCE \(name) sha256=\(digest(data))")
            }
            for mac in [false, true] {
                let report = try sourceReport(sources, macImport: mac)
                try require(report.exitCode == 1 && report.ownership.count == 2, "U1 model failed")
                try require(Set(report.ownership.map { $0.registration.name }) ==
                            ["ProductionAccessScopeTests", "ProductionAccessScopeSuiteTests"], "wrong U1 roots")
                try require(report.ownership.allSatisfy { !$0.annotationSatisfied }, "U1 file exemption")
                try require(report.ownership.reduce(0) { $0 + $1.tests.count } == 9, "U1 test obligations missing")
            }
        }
    }

    func rejectLegacy(_ name: String, first: String, second: String = "") throws {
        let fixture = try world(name, annotated: true)
        try fixture.register(fixture.run().derivedRegistrations)
        try require(fixture.run().enforcementSatisfied, "canonical registered control failed")
        try fixture.write("Sources/A.swift",
                          "@Suite(.productionAccessAudit) struct Example { @Test func body() {} }\n" + first)
        try fixture.write("Mac/B.swift", second)
        for mode in ["enforce", "inventory"] {
            let report = fixture.run(mode: mode)
            try report.encoded().write(to: fixture.root.appendingPathComponent(mode + "-result.json"))
            try require(report.exitCode == 2 && !report.analysisComplete && !report.enforcementSatisfied &&
                        report.diagnostics.contains { $0.category == "model" && $0.message.contains("XCTest") },
                        "unsupported XCTest discovery escaped beside fully registered canonical suites")
        }
    }

    func legacyDiscoveryCases() {
        test("unannotated direct qualified and empty XCTest subclasses fail structurally") {
            for (number, source) in [
                "import XCTest\nclass LegacyTests: XCTestCase { func testAccess() {} }",
                "class LegacyTests: XCTest.XCTestCase { func testAccess() async throws {} }",
                "class LegacyTests: XCTestCase {}",
                "class `LegacyTests`: XCTestCase { func `testAccess`() {} }"
            ].enumerated() { try rejectLegacy("legacy-direct-\(number)", first: source) }
        }
        test("cross-file transitive XCTest classes aliases and nested aliases fail structurally") {
            try rejectLegacy("legacy-transitive", first: "class Base: XCTestCase {}\nclass Middle: Base {}",
                             second: "class LegacyTests: Middle { func testAccess() {} }")
            try rejectLegacy("legacy-alias", first: "typealias Base = XCTest.XCTestCase\ntypealias Next = Base",
                             second: "class LegacyTests: Next { func testAccess() {} }")
            try rejectLegacy("legacy-nested-alias", first: "enum Names { typealias Base = XCTestCase }",
                             second: "class LegacyTests: Names.Base { func testAccess() {} }")
        }
        test("test-shaped inherited classes fail closed for unresolved ambiguous and cyclic bases") {
            try rejectLegacy("legacy-unresolved", first: "class LegacyTests: ExternalBase { func testAccess() {} }")
            try rejectLegacy("legacy-cycle", first: "typealias Base = Next\ntypealias Next = Base",
                             second: "class LegacyTests: Base { func testAccess() {} }")
            try rejectLegacy("legacy-ambiguous", first: "class Base {}\nclass Base {}",
                             second: "class LegacyTests: Base { func testAccess() {} }")
            try rejectLegacy("legacy-private-alias", first: "private typealias Base = ExternalBase",
                             second: "class LegacyTests: Base { func testAccess() {} }")
        }
        test("test-shaped extension members cannot bypass inherited class checks") {
            try rejectLegacy("legacy-extension", first: "class LegacyTests: ExternalBase {}",
                             second: "extension LegacyTests { func testAccess() {} }")
            try rejectLegacy("legacy-external-extension", first: "extension XCTestCase { func testAccess() {} }")
        }
        test("plain inherited and generic helpers plus resolved non-XCTest test-shaped helpers remain valid") {
            let source = """
            class PlainBase {}
            typealias HelperBase = PlainBase
            class Helper: HelperBase { func testUtility() {} }
            class ExternalHelper: UnknownBase { func use() {} }
            class GenericHelper<T>: UnknownBase { func testValue(_ value: T) {} }
            class FactoryHelper: UnknownBase { static func testFactory() {} }
            class ValueHelper: UnknownBase { func testEnabled() -> Bool { false } }
            struct Plain { func testUtility() {} }
            extension Plain { func testOther() {} }
            @Suite(.productionAccessAudit) struct Root { @Test func body() {} }
            """
            // The former UnknownBase/Bool positive guessed inherited Bool was
            // absent. Retain it as a rejection, then prove the known-base control.
            try rejects({ _ = try sourceReport([("A.swift", source)]) }, containing: "XCTest")
            let known = source.replacingOccurrences(of: "ValueHelper: UnknownBase", with: "ValueHelper: PlainBase")
            let report = try sourceReport([("A.swift", known)])
            try require(report.exitCode == 0 && report.ownership.count == 1, "plain helpers rejected")
        }
        test("legacy inheritance follows consistent conditional variants and reversed declaration order") {
            let sources = [("A.swift", """
            #if canImport(FluxKlangMac)
            typealias Base = XCTestCase
            #else
            class Base {}
            #endif
            """), ("B.swift", "class Legacy: Base { func testAccess() {} }")]
            try require(try sourceReport(sources).exitCode == 0, "ordinary variant rejected")
            for ordered in [sources, Array(sources.reversed())] {
                try rejects({ _ = try sourceReport(ordered, macImport: true) }, containing: "XCTest")
            }
        }
    }

    func observationCases() {
        test("standard Testing source-location expression remains bounded and does not create obligations") {
            let report = try sourceReport([("A.swift", """
            import Testing
            func expectRefusal(sourceLocation: SourceLocation = #_sourceLocation) {}
            @Suite(.productionAccessAudit) struct Root { @Test func body() { expectRefusal() } }
            """)])
            try require(report.exitCode == 0 && report.ownership.count == 1, "standard source-location rejected")
            for source in ["let value = #_sourceLocation(injected: true)", "let value = #_sourceLocationAlias"] {
                try rejects { _ = try sourceReport([("A.swift", source)]) }
            }
        }
        test("actual Observation helpers preserve imports and remain ordinary helpers") {
            let names = ["AssistantMixerExecutionTests.swift", "AssistantActionPlanningTests.swift"]
            let sources = try names.map {
                ("FluxKlangTests/" + $0, try String(contentsOf: u1Root.appendingPathComponent($0), encoding: .utf8))
            }
            let report = try sourceReport(sources)
            try require(report.exitCode == 1 && report.analysisComplete && report.ownership.count == 2,
                        "standard Observable helpers changed source obligations")
        }
        test("standard qualified Observable is bounded; conflicting or opaque macros still fail closed") {
            let valid = try sourceReport([("A.swift", """
            import Observation
            @Observation.Observable final class Helper { var count = 0 }
            @Suite(.productionAccessAudit) struct Root { @Test func body() {} }
            """)])
            try require(valid.exitCode == 0 && valid.ownership.count == 1, "qualified Observable failed")
            for source in ["@Other.Observable class Helper {}", "@ObservableWrapper class Helper {}",
                           "@Observable(injected: true) class Helper {}", "@Observable struct Wrong {}",
                           "macro Observable() = #externalMacro(module: \"Other\", type: \"Opaque\")"] {
                try rejects { _ = try sourceReport([("A.swift", source)]) }
            }
        }
    }
}
#endif
