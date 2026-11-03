import Foundation

#if AUDIT_CHECK_TESTS
extension FixtureTests {
    func inheritedReturnCases() {
        test("inherited primitive alias shadows fallback beside registered canonical suites") {
            try rejectLegacy("inherited-primitive", first: """
            class Base: ExternalBase { typealias Int = Void }
            class Legacy: Base { func testAccess() -> Int {} }
            """)
        }
        test("inherited aliases shadow source nominals in methods and cross-file extensions") {
            try rejectLegacy("inherited-nominal", first: """
            struct Value {}
            class Base: ExternalBase { typealias Value = Void }
            class Legacy: Base { func testAccess() -> Value {} }
            """)
            try rejectLegacy("inherited-extension", first: """
            struct Value {}
            class Base: ExternalBase { typealias Int = (); typealias Value = Void }
            class Legacy: Base {}
            """, second: "extension Legacy { func testInt() -> Int {}; func testValue() -> Value {} }")
        }
        test("transitive inherited aliases and reversed file order cannot evade ancestry refusal") {
            try rejectLegacy("inherited-transitive", first: """
            class Base: ExternalBase { typealias Int = Void }
            typealias Middle = Base
            class Next: Middle {}
            """, second: "class Legacy: Next { func testAccess() -> Int {} }")
            let sources = [("A.swift", "class Base: ExternalBase { typealias Int = Void }"),
                           ("B.swift", "class Legacy: Base { func testAccess() -> Int {} }")]
            for ordered in [sources, Array(sources.reversed())] {
                try rejects({ _ = try sourceReport(ordered) }, containing: "XCTest")
            }
        }
        test("ambiguous inaccessible generic and cyclic inheritance cannot prove non-Void returns") {
            for (number, source) in [
                """
                class First: ExternalBase { typealias Int = [Void] }
                class Second { typealias Int = Void }
                class Legacy: First, Second { func testAccess() -> Int {} }
                """,
                """
                class Base<T>: ExternalBase { typealias Int = T }
                class Legacy: Base<Void> { func testAccess() -> Int {} }
                """,
                """
                class Safe { typealias Int = [Void] }
                class Outer: ExternalBase { class Legacy: Safe { func testAccess() -> Int {} } }
                """,
                "class Safe {}\nclass Legacy<Safe>: Safe { func testAccess() -> Int {} }",
                """
                typealias Value = Void
                class Base: ExternalBase { private typealias Value = [Void] }
                class Legacy: Base { func testAccess() -> Value {} }
                """,
                "typealias Base = Next\ntypealias Next = Base\nclass Legacy: Base { func testAccess() -> Int {} }"
            ].enumerated() { try rejectLegacy("inherited-uncertain-\(number)", first: source) }
            try rejectLegacy("inherited-private", first: """
            class Base: ExternalBase { private typealias Int = Void }
            """, second: "class Legacy: Base { func testAccess() -> Int {} }")
        }
        test("unknown ancestry cannot establish absence of primitive nominal or module-name shadowing") {
            for (number, result) in ["Bool", "Value", "Swift.Bool"].enumerated() {
                try rejectLegacy("inherited-unknown-\(number)", first: """
                struct Value {}
                class Legacy: ExternalBase { func testAccess() -> \(result) {} }
                """)
            }
        }
        test("explicit genuinely non-Void inherited aliases remain valid helpers with unknown ancestry") {
            let fixture = try world("inherited-nonvoid", annotated: true)
            try fixture.register(fixture.run().derivedRegistrations)
            try fixture.write("Sources/A.swift", """
            @Suite(.productionAccessAudit) struct Example { @Test func body() {} }
            struct Value {}
            class Base: ExternalBase {
                typealias Int = [Void]
                typealias Value = (Void, Void)
            }
            typealias Middle = Base
            class Legacy: Middle {
                func testInt() -> Int { [] }
                func testValue() -> Value { ((), ()) }
            }
            """)
            try fixture.write("Mac/B.swift", "extension Legacy { func testExtension() -> Int { [] } }")
            let report = fixture.run()
            try report.encoded().write(to: fixture.root.appendingPathComponent("enforce-result.json"))
            try require(report.enforcementSatisfied && report.exitCode == 0,
                        "proved inherited non-Void aliases rejected")
        }
        test("inherited return aliases use consistent conditional variants") {
            try inheritedConditionalCases()
        }
    }

    func extensionAccessCases() {
        for access in ["private", "fileprivate"] {
            test("\(access) extension alias cannot prove cross-file non-Void return") {
                try rejectLegacy("extension-access-alias-\(access)", first: """
                class Base: ExternalBase {}
                \(access) extension Base { typealias Result = [Void] }
                """, second: "typealias Result = Void\nclass Legacy: Base { func testAccess() -> Result {} }")
            }
            test("\(access) extension nominal cannot prove cross-file non-Void return") {
                try rejectLegacy("extension-access-nominal-\(access)", first: """
                class Base: ExternalBase {}
                \(access) extension Base { struct Result {} }
                """, second: "typealias Result = Void\nclass Legacy: Base { func testAccess() -> Result {} }")
            }
        }
        test("unrestricted extension aliases and nominals remain valid cross-file non-Void bindings") {
            let fixture = try world("extension-access-unrestricted", annotated: true)
            try fixture.register(fixture.run().derivedRegistrations)
            try fixture.write("Sources/A.swift", """
            @Suite(.productionAccessAudit) struct Example { @Test func body() {} }
            class Base: ExternalBase {}
            extension Base { typealias Result = [Void]; struct Value {} }
            """)
            try fixture.write("Mac/B.swift", """
            typealias Result = Void
            typealias Value = Void
            class Legacy: Base {
                func testAccess() -> Result { [] }
                func testValue() -> Value { Value() }
            }
            """)
            for mode in ["enforce", "inventory"] {
                let report = fixture.run(mode: mode)
                try report.encoded().write(to: fixture.root.appendingPathComponent(mode + "-result.json"))
                try require(report.exitCode == 0 && report.enforcementSatisfied, "unrestricted extension rejected")
            }
        }
        test("effective extension restriction reaches nested nominal and alias records") {
            for access in ["private", "fileprivate", ""] {
                let matrix = MatrixRow(target: "FixtureTests", module: "FixtureTests",
                                       platform: "iOS", configuration: "Debug")
                var inventory = SourceInventory(variant: SourceVariant(
                    matrix: matrix, macImport: false, modelsImport: false))
                try inventory.add(ParsedSource(path: "A.swift", text: """
                class Base {}
                \(access) extension Base {
                    typealias Result = [Void]
                    struct Container { typealias Nested = [Void]; struct Inner {} }
                }
                """))
                let members = inventory.nominals.filter { $0.parent != nil }
                let expected = !access.isEmpty
                try require(members.count == 2 && inventory.aliases.count == 2, "missing nested fixture members")
                try require(members.allSatisfy { $0.restricted == expected } &&
                            inventory.aliases.allSatisfy { $0.restricted == expected },
                            "effective extension access was lost")
            }
        }
    }

    func macroSyntaxCases() {
        test("parameterized free Test default string some is not an opaque type keyword") {
            for (number, value) in ["\"some\"", "#\"some\"#"].enumerated() {
                let fixture = try world("syntax-default-\(number)", annotated: true)
                try fixture.write("Sources/A.swift", """
                import Testing
                @Test(.productionAccessAudit, arguments: ["x"]) func body(_ value: String = \(value)) {}
                """)
                let derived = fixture.run()
                try derived.encoded().write(to: fixture.root.appendingPathComponent("pre-registration.json"))
                try require(derived.analysisComplete, "default string incorrectly classified as opaque")
                try fixture.register(derived.derivedRegistrations)
                try require(fixture.run().enforcementSatisfied, "canonical parameterized free Test failed")
            }
        }
        test("actual opaque and generic Testing functions remain unsupported") {
            for source in [
                "@Test(.productionAccessAudit, arguments: [1]) func body(_ value: some Equatable) {}",
                "@Test(.productionAccessAudit, arguments: [1]) func body<T>(_ value: T) {}"
            ] { try rejects({ _ = try sourceReport([("A.swift", source)]) }, containing: "generic") }
        }
        test("conditional and nested conditional Observable attributes retain their class owner") {
            let source = """
            import Observation
            #if DEBUG
            #if os(macOS)
            @Observation.Observable
            #else
            @Observable
            #endif
            #endif
            class Helper { var value = 0 }
            @Suite(.productionAccessAudit) struct Example { @Test func body() {} }
            """
            let fixture = try world("syntax-observable", annotated: true)
            try fixture.register(fixture.run().derivedRegistrations)
            try fixture.write("Sources/A.swift", source)
            let report = fixture.run()
            try report.encoded().write(to: fixture.root.appendingPathComponent("enforce-result.json"))
            try require(report.enforcementSatisfied, "conditional class attribute rejected")
            for configuration in ["Debug", "Release"] {
                for platform in ["iOS", "macOS"] {
                    let result = try sourceReport([("A.swift", source)],
                                                  configuration: configuration, platform: platform)
                    try require(result.exitCode == 0 && result.ownership.count == 1, "conditional owner drift")
                }
            }
        }
        test("conditional Observable cannot climb past a non-class declaration or hide unsupported syntax") {
            for source in [
                "#if DEBUG\n@Observable\n#endif\nstruct Wrong {}",
                "class Container {\n#if DEBUG\n@Observable\n#endif\nfunc wrong() {}\n}",
                "#if DEBUG\n@CustomObservable\n#endif\nclass Wrong {}",
                "#if compiler(>=6)\n@Observable\n#endif\nclass Wrong {}"
            ] {
                for configuration in ["Debug", "Release"] {
                    try rejects { _ = try sourceReport([("A.swift", source)], configuration: configuration) }
                }
            }
        }
    }

    func outerTypeCases() {
        test("default closure local opaque helper is not an outer generic Testing signature") {
            let fixture = try world("outer-default-closure", annotated: true)
            try fixture.write("Sources/A.swift", """
            @Suite(.productionAccessAudit) struct Example { @Test func body() {} }
            @Test(.productionAccessAudit, arguments: ["x"])
            func closureDefault(_ value: String = {
                func helper(_ input: some Equatable) -> String { "x" }
                return helper(1)
            }()) {}
            """)
            let report = fixture.run()
            try report.encoded().write(to: fixture.root.appendingPathComponent("pre-registration.json"))
            try require(report.analysisComplete, "default closure was scanned as an outer type")
            try fixture.register(report.derivedRegistrations)
            try require(fixture.run().enforcementSatisfied, "canonical closure-default Test failed")
        }
        test("outer opaque return parameter and explicit generic types remain unsupported") {
            for source in [
                "@Test(.productionAccessAudit) func body() -> some Equatable { 1 }",
                "@Test(.productionAccessAudit, arguments: [1]) func body(_ value: some Equatable) {}",
                "@Test(.productionAccessAudit, arguments: [1]) func body<T: Equatable>(_ value: T) {}"
            ] { try rejects({ _ = try sourceReport([("A.swift", source)]) }, containing: "generic") }
        }
    }

    func ancestryHopSafeguards() {
        test("nearest ancestry hops preserve generic ambiguous cyclic unknown and restricted refusal") {
            for (number, body) in [
                "typealias Parent = Missing; class Legacy: Parent { func testAccess() {} }",
                "typealias Parent = Loop; typealias Loop = Parent; class Legacy: Parent { func testAccess() {} }",
                "typealias Parent = Plain; class Legacy<Parent>: Parent { func testAccess() {} }",
                "typealias Parent = Plain; typealias Parent = Missing; class Legacy: Parent { func testAccess() {} }"
            ].enumerated() {
                try rejectLegacy("unqualified-uncertain-\(number)", first:
                    "class Plain {}\ntypealias Parent = Plain\nenum Outer { \(body) }")
            }
            try rejectLegacy("unqualified-restricted", first: """
            class Plain {}
            typealias Parent = Plain
            enum Outer { private typealias Parent = Plain }
            """, second: "extension Outer { class Legacy: Parent {} }")
        }
    }

    private func inheritedConditionalCases() throws {
        let sources = [("A.swift", """
        class Base: ExternalBase {
        #if canImport(FluxKlangMac) && canImport(FoundationModels)
            typealias Int = ()
        #else
            typealias Int = [Void]
        #endif
        }
        """), ("B.swift", "class Legacy: Base { func testAccess() -> Int {} }")]
        for mac in [false, true] {
            for models in [false, true] {
                if mac && models {
                    try rejects({
                        _ = try sourceReport(sources, macImport: mac, modelsImport: models)
                    }, containing: "XCTest")
                } else {
                    let report = try sourceReport(sources, macImport: mac, modelsImport: models)
                    try require(report.exitCode == 0, "proved inherited non-Void variant rejected")
                }
            }
        }
    }
}
#endif

struct InventoryRow: Codable {
    let registration: Registration
    let line: Int
    let annotationSatisfied: Bool
    let annotationProblems: [String]
    let tests: [SourceSite]
}

struct AuditDiagnostic: Codable, Hashable {
    let category: String
    let message: String
    let registration: Registration?
    let site: SourceSite?

    var sortKey: String {
        [category, registration?.sortKey ?? "", site?.path ?? "", String(site?.line ?? 0), message]
            .joined(separator: "\u{1F}")
    }
}

struct AuditReport: Encodable {
    var schemaVersion = 1
    let purpose = "source-registration-only"
    let identityNotice = "Source identities/guards only; not public Test.ID, case IDs or runtime receipt expectations."
    let membershipNotice = "Digest-bound REVIEWED transcription; digest verification does not parse YAML."
    let conditionNotice = "Consistent symbolic canImport variants, not inferred SDK availability."
    var mode: String
    var analysisComplete = false
    var enforcementSatisfied = false
    var exitCode = 2
    var inputHashes: [String: String] = [:]
    var derivedRegistrations: [Registration] = []
    var ownership: [InventoryRow] = []
    var diagnostics: [AuditDiagnostic] = []
    var targetRoles: [TargetRole]?
    var qualification: QualificationReport?

    mutating func finish() {
        diagnostics = Set(diagnostics).sorted { $0.sortKey < $1.sortKey }
        ownership.sort { $0.registration.sortKey < $1.registration.sortKey }
        derivedRegistrations = ownership.map(\.registration)
        let invalid = diagnostics.contains { ["model", "input", "qualification"].contains($0.category) }
        qualification?.inventory.sort { $0.sortKey < $1.sortKey }
        let qualified = !invalid && qualification?.inventory.count == 16
        qualification?.contractSatisfied = qualified
        analysisComplete = !invalid
        enforcementSatisfied = !invalid && diagnostics.isEmpty
        exitCode = invalid ? 2 : (enforcementSatisfied || mode == "inventory" ? 0 : 1)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct CheckOptions {
    var root: String
    var manifest = "scripts/test-audit-coverage/registrations.json"
    var mode = "enforce"
    var format = "json"

    static func parse(_ arguments: [String]) throws -> CheckOptions {
        try require(arguments.count.isMultiple(of: 2), "usage: Check --root PATH [--manifest PATH] " +
                    "[--mode enforce|inventory] [--format json|text]")
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            try require(["--root", "--manifest", "--mode", "--format"].contains(key) && values[key] == nil,
                        "unknown/duplicate CLI option: \(key)")
            values[key] = arguments[index + 1]
        }
        guard let root = values["--root"] else { throw AuditFailure("--root is required") }
        var result = CheckOptions(root: root)
        result.manifest = values["--manifest"] ?? result.manifest
        result.mode = values["--mode"] ?? result.mode
        result.format = values["--format"] ?? result.format
        try require(["enforce", "inventory"].contains(result.mode), "unsupported mode")
        try require(["json", "text"].contains(result.format), "unsupported report format")
        // Manifest paths are root-relative, just like every bound input.
        try SafeInputs.validatePath(result.manifest)
        return result
    }
}

enum AuditChecker {
    static func run(_ options: CheckOptions) -> AuditReport {
        var report = AuditReport(mode: options.mode)
        var inputs: SafeInputs?
        do {
            let captured = try SafeInputs(root: options.root)
            inputs = captured
            let data = try captured.read(options.manifest)
            // An untrusted version discriminator selects only the failure-report
            // envelope. Strict decoding below still validates every key and value.
            if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int == 2 {
                report.schemaVersion = 2
                report.targetRoles = TargetRoleContract.roles
                report.qualification = QualificationReport()
            }
            let manifest = try AuditManifest.load(data)
            try require(digest(captured.read(manifest.specification.path)) == manifest.specification.sha256,
                        "reviewed specification digest mismatch; no automatic refresh/trust operation")
            let pbx = try ProjectMembership(data: captured.read(manifest.pbxPath))
            let memberships = try pbx.validate(manifest, inputs: captured)
            let paths = Set(memberships.values.flatMap { $0 }).sorted()
            var parsed: [String: ParsedSource] = [:]
            for path in paths {
                guard let text = String(data: try captured.read(path, role: .source), encoding: .utf8) else {
                    throw AuditFailure("source is not UTF8: \(path)")
                }
                parsed[path] = try ParsedSource(path: path, text: text)
            }
            try inventory(manifest: manifest, memberships: memberships, parsed: parsed, report: &report)
            compareRegistrations(manifest.registrations, report: &report)
        } catch {
            report.diagnostics.append(AuditDiagnostic(category: "input", message: String(describing: error),
                                                      registration: nil, site: nil))
        }
        if let inputs {
            do { try inputs.verifyUnchanged() } catch {
                report.diagnostics.append(AuditDiagnostic(category: "input", message: String(describing: error),
                                                          registration: nil, site: nil))
            }
            report.inputHashes = inputs.hashes
        }
        report.finish()
        return report
    }

    static func compareRegistrations(_ expected: [Registration]?, report: inout AuditReport) {
        let actual = Set(report.ownership.map(\.registration))
        let registrations = expected ?? []
        if registrations.isEmpty {
            report.diagnostics.append(AuditDiagnostic(
                category: "registration", message: "missing/empty registration list is incomplete",
                registration: nil, site: nil))
        }
        let counts = Dictionary(grouping: registrations, by: { $0 })
        for (row, duplicates) in counts where duplicates.count > 1 {
            report.diagnostics.append(AuditDiagnostic(category: "registration", message: "duplicate registration",
                                                      registration: row, site: nil))
        }
        for row in actual.subtracting(registrations) {
            report.diagnostics.append(AuditDiagnostic(category: "registration", message: "missing registration",
                                                      registration: row, site: nil))
        }
        for row in Set(registrations).subtracting(actual) {
            report.diagnostics.append(AuditDiagnostic(category: "registration", message: "stale registration",
                                                      registration: row, site: nil))
        }
    }

    static func execute(_ arguments: [String]) -> (Data, Int32) {
        do {
            let options = try CheckOptions.parse(arguments)
            let report = run(options)
            if options.format == "text" {
                let lines = ["mode=\(report.mode) analysisComplete=\(report.analysisComplete) " +
                             "enforcementSatisfied=\(report.enforcementSatisfied) exitCode=\(report.exitCode)"] +
                    report.ownership.map {
                        "\($0.registration.sortKey) annotationSatisfied=\($0.annotationSatisfied)"
                    } + (report.qualification?.textLines ?? []) +
                    report.diagnostics.map { "\($0.category): \($0.registration?.sortKey ?? "") \($0.message)" }
                return (Data((lines.joined(separator: "\n") + "\n").utf8), Int32(report.exitCode))
            }
            return (try report.encoded() + Data([10]), Int32(report.exitCode))
        } catch {
            var report = AuditReport(mode: "enforce")
            report.diagnostics = [AuditDiagnostic(category: "input", message: String(describing: error),
                                                   registration: nil, site: nil)]
            report.finish()
            let fallback = Data("{\"exitCode\":2,\"enforcementSatisfied\":false}\n".utf8)
            return ((try? report.encoded()) ?? fallback, 2)
        }
    }
}

#if !AUDIT_CHECK_TESTS
@main
enum CheckMain {
    static func main() {
        let (data, code) = AuditChecker.execute(Array(CommandLine.arguments.dropFirst()))
        FileHandle.standardOutput.write(data)
        exit(code)
    }
}
#endif
