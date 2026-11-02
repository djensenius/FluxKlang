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
    let schemaVersion = 1
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

    mutating func finish() {
        diagnostics = Set(diagnostics).sorted { $0.sortKey < $1.sortKey }
        ownership.sort { $0.registration.sortKey < $1.registration.sortKey }
        derivedRegistrations = ownership.map(\.registration)
        let invalid = diagnostics.contains { $0.category == "model" || $0.category == "input" }
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
            let manifest = try AuditManifest.load(captured.read(options.manifest))
            try require(digest(captured.read(manifest.specification.path)) == manifest.specification.sha256,
                        "reviewed specification digest mismatch; no automatic refresh/trust operation")
            let pbx = try ProjectMembership(data: captured.read(manifest.pbxPath))
            let memberships = try pbx.validate(manifest, inputs: captured)
            let paths = Set(memberships.values.flatMap { $0 }).sorted()
            var parsed: [String: ParsedSource] = [:]
            for path in paths {
                guard let text = String(data: try captured.read(path), encoding: .utf8) else {
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

    private static func inventory(
        manifest: AuditManifest, memberships: [String: [String]], parsed: [String: ParsedSource],
        report: inout AuditReport
    ) throws {
        for matrix in manifest.matrix.sorted(by: {
            $0.target + $0.configuration < $1.target + $1.configuration
        }) {
            for macImport in [false, true] {
                for modelsImport in [false, true] {
                    let variant = SourceVariant(matrix: matrix, macImport: macImport, modelsImport: modelsImport)
                    do {
                        var inventory = SourceInventory(variant: variant)
                        for path in memberships[matrix.target] ?? [] {
                            guard let source = parsed[path] else { throw AuditFailure("missing parsed member") }
                            try inventory.add(source)
                        }
                        let result = try SourceOwnership(inventory).analyze()
                        report.ownership += result.rows
                        report.diagnostics += result.diagnostics
                    } catch {
                        let scope = "\(matrix.target)/\(matrix.configuration)/\(variant.guardExpression)"
                        report.diagnostics.append(AuditDiagnostic(
                            category: "model", message: "\(scope): \(error)", registration: nil, site: nil))
                    }
                }
            }
        }
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
                    } + report.diagnostics.map { "\($0.category): \($0.registration?.sortKey ?? "") \($0.message)" }
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
