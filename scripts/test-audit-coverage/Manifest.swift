import CryptoKit
import Foundation

struct AuditFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw AuditFailure(message) }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// Foundation decoders discard duplicate keys. This independent lexical pass validates
// every object (including escaped key spellings) BEFORE Foundation decodes the schema.
struct JSONKeyCheck {
    let bytes: [UInt8]
    var offset = 0

    mutating func validate() throws {
        try value(depth: 0)
        space()
        try require(offset == bytes.count, "JSON trailing input")
    }

    mutating func space() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    mutating func take(_ byte: UInt8) -> Bool {
        space()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    mutating func string() throws -> String {
        space()
        let start = offset
        try require(take(34), "JSON string expected")
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
            if byte == 92 { offset += 1 }
        }
        throw AuditFailure("JSON unterminated string")
    }

    mutating func value(depth: Int) throws {
        try require(depth < 128, "JSON nesting limit")
        space()
        if take(123) {
            var keys = Set<String>()
            if take(125) { return }
            repeat {
                let key = try string()
                try require(keys.insert(key).inserted, "JSON duplicate key: \(key)")
                try require(take(58), "JSON colon expected")
                try value(depth: depth + 1)
            } while take(44)
            try require(take(125), "JSON closing object expected")
        } else if take(91) {
            if take(93) { return }
            repeat { try value(depth: depth + 1) } while take(44)
            try require(take(93), "JSON closing array expected")
        } else if offset < bytes.count && bytes[offset] == 34 {
            _ = try string()
        } else {
            let start = offset
            while offset < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            try require(offset > start, "JSON value expected")
            _ = try JSONSerialization.jsonObject(with: Data(bytes[start..<offset]), options: .fragmentsAllowed)
        }
    }
}

struct MatrixRow: Codable, Hashable {
    let target: String
    let module: String
    let platform: String
    let configuration: String
}

struct SourceMembership: Codable {
    let target: String
    let directories: [String]
    let files: [String]
}

// Each row is one SOURCE obligation in one configuration/symbolic variant.
// `name` is a qualified nominal name or normalized free-function signature tokens.
// These values are never Testing.Test.ID, case IDs, or receipt expectations.
struct Registration: Codable, Hashable {
    let target: String
    let module: String
    let path: String
    let kind: String
    let name: String
    let configuration: String
    let guardExpression: String
    let requirement: String

    var sortKey: String {
        [target, module, path, kind, name, configuration, guardExpression, requirement].joined(separator: "\u{1F}")
    }
}

struct AuditManifest: Decodable {
    struct Specification: Decodable {
        let path: String
        let sha256: String
        let review: String
    }
    let schemaVersion: Int
    let purpose: String
    let specification: Specification
    let pbxPath: String
    let matrix: [MatrixRow]
    let sources: [SourceMembership]
    let registrations: [Registration]?
    let targetRoles: [TargetRole]?
    let qualification: QualificationContract?

    static func load(_ data: Data) throws -> AuditManifest {
        try require(data.count <= 32_000_000, "manifest size limit")
        var keyCheck = JSONKeyCheck(bytes: Array(data))
        try keyCheck.validate()
        let object = try JSONSerialization.jsonObject(with: data)
        let version = (object as? [String: Any])?["schemaVersion"] as? Int
        let roleKeys: Set<String> = version == 2 ? ["targetRoles", "qualification"] : []
        let root = try fields(object, required: Set([
            "schemaVersion", "purpose", "specification", "pbxPath", "matrix", "sources"
        ]).union(roleKeys), optional: ["registrations"])
        _ = try fields(root["specification"], required: ["path", "sha256", "review"])
        try rows(root["matrix"], keys: ["target", "module", "platform", "configuration"])
        try rows(root["sources"], keys: ["target", "directories", "files"])
        if version == 2 {
            try rows(root["targetRoles"], keys: ["target", "role"])
            let qualification = try fields(root["qualification"], required: ["target", "tests"])
            try rows(qualification["tests"], keys: ["path", "owner", "signature"])
        }
        if let registrations = root["registrations"] {
            try rows(registrations, keys: [
                "target", "module", "path", "kind", "name", "configuration", "guardExpression", "requirement"
            ])
        }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }

    private static func fields(
        _ value: Any?, required: Set<String>, optional: Set<String> = []
    ) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw AuditFailure("manifest object expected") }
        let keys = Set(object.keys)
        try require(required.isSubset(of: keys) && keys.isSubset(of: required.union(optional)),
                    "manifest missing/unknown fields: \(keys.sorted())")
        return object
    }

    private static func rows(_ value: Any?, keys: Set<String>) throws {
        guard let array = value as? [Any] else { throw AuditFailure("manifest array expected") }
        for row in array { _ = try fields(row, required: keys) }
    }

    private func validate() throws {
        try require([1, 2].contains(schemaVersion) && purpose == "source-registration-only", "manifest version/purpose")
        try require(specification.path == "project.yml" && specification.review == "REVIEWED",
                    "specification must be an explicitly REVIEWED project.yml transcription")
        try require(specification.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                    "specification SHA256 must be lowercase hex")
        try SafeInputs.validatePath(pbxPath)
        try require(pbxPath.split(separator: "/").count == 2 &&
                    pbxPath.hasSuffix(".xcodeproj/project.pbxproj"),
                    "PBX path must name one repository-root .xcodeproj/project.pbxproj")
        if schemaVersion == 2 { try TargetRoleContract.validate(self) }
        let auditedMatrix = matrix.filter { schemaVersion == 1 || $0.target != TargetRoleContract.target }
        try require(auditedMatrix.count == 4 && Set(auditedMatrix).count == 4, "matrix requires four unique rows")
        for platform in ["iOS", "macOS"] {
            let rows = auditedMatrix.filter { $0.platform == platform }
            try require(rows.count == 2 && Set(rows.map(\.configuration)) == ["Debug", "Release"],
                        "matrix requires Debug/Release for \(platform)")
            try require(Set(rows.map(\.target)).count == 1 && Set(rows.map(\.module)).count == 1,
                        "matrix target/module drift")
        }
        try require(Set(auditedMatrix.map(\.target)).count == 2, "matrix requires two distinct unit targets")
        for row in matrix {
            for name in [row.target, row.module] {
                try require(name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                            "unsupported target/module identifier")
            }
        }
        try require(sources.count == (schemaVersion == 2 ? 3 : 2) &&
                    Set(sources.map(\.target)) == Set(matrix.map(\.target)),
                    "source memberships must bind both targets exactly once")
        for source in sources {
            let paths = source.directories + source.files
            try require(!paths.isEmpty && Set(paths).count == paths.count, "empty/duplicate source entries")
            for path in paths { try SafeInputs.validatePath(path) }
            try require(source.files.allSatisfy { $0.hasSuffix(".swift") }, "explicit sources must be Swift")
        }
        for row in registrations ?? [] {
            try SafeInputs.validatePath(row.path)
            try require(["root", "freeTest"].contains(row.kind) && !row.name.isEmpty, "registration kind/name")
            try require(row.requirement == "canonicalProductionAccessAudit", "unsupported registration requirement")
            try require(auditedMatrix.contains {
                $0.target == row.target && $0.module == row.module && $0.configuration == row.configuration
            }, "registration outside matrix")
            try require(SourceVariant.guards.contains(row.guardExpression), "unsupported registration guard")
        }
        // Duplicate/stale/missing registrations are reported as obligations, not hidden by schema decoding.
    }
}

#if AUDIT_CHECK_TESTS
extension FixtureTests {
    func specializedAncestryCases() {
        let names = "import class XCTest.XCTestCase\nenum Names<T> { typealias Base = XCTestCase }"
        test("ordinary unqualified generic ancestry and aliases remain non-test helpers") {
            let fixture = try world("specialized-ordinary", annotated: true)
            try fixture.register(fixture.run().derivedRegistrations)
            try fixture.write("Sources/A.swift", """
            @Suite(.productionAccessAudit) struct Example { @Test func body() {} }
            class Base<T> {}
            typealias Parent<T> = Base<T>
            class Helper: Parent<Int> {}
            """)
            try require(fixture.run().enforcementSatisfied, "ordinary generic helper ancestry was over-rejected")
        }
        test("specialized source namespace cannot hide an empty XCTest subclass") {
            try rejectLegacy("specialized-direct", first: names + "\nclass Legacy: Names<Int>.Base {}")
        }
        test("specialized ancestry survives parenthesized cross-file alias chains and reversed order") {
            let first = names + "\ntypealias Parent = ((Names<Int>.Base))"
            let second = "typealias Middle = Parent\nclass Legacy: Middle {}"
            try rejectLegacy("specialized-chain", first: first, second: second)
            for ordered in [[("A.swift", first), ("B.swift", second)], [("B.swift", second), ("A.swift", first)]] {
                try rejects({ _ = try sourceReport(ordered) }, containing: "XCTest")
            }
        }
        test("specialized generic ancestry aliases cannot lose their source binding") {
            try rejectLegacy("specialized-generic-alias", first: names + """

            typealias Parent<T> = Names<T>.Base
            class Legacy: Parent<Int> {}
            """)
        }
        test("nested and shadowed specialized namespaces are refused without generic inference") {
            try rejectLegacy("specialized-nested", first: """
            import class XCTest.XCTestCase
            enum Container { enum Names<T> { typealias Base = XCTestCase } }
            class Legacy: Container.Names<Int>.Base {}
            """)
            try rejectLegacy("specialized-shadowed", first: names + """

            enum Outer { typealias Names<T> = External<T>; class Legacy: Names<Int>.Base {} }
            """)
        }
    }

    func parenthesizedAncestryCases() {
        test("transparent parenthesized ancestry aliases cannot hide empty XCTest subclasses") {
            for (number, base) in ["(XCTest.XCTestCase)", "(XCTestCase)", "(((XCTestCase)))"].enumerated() {
                try rejectLegacy("ancestry-parens-\(number)", first: """
                import class XCTest.XCTestCase
                typealias Base = \(base)
                class LegacyTests: Base {}
                """)
            }
        }
        test("parenthesized cross-file chains and nested ancestry aliases remain XCTest ancestry") {
            try rejectLegacy("ancestry-chain", first: "import XCTest\ntypealias First = ((XCTestCase))",
                             second: "typealias Base = (First)\nclass LegacyTests: Base {}")
            try rejectLegacy("ancestry-nested", first: """
            import class XCTest.XCTestCase
            enum Names { typealias Base = ((XCTest.XCTestCase)) }
            class LegacyTests: Names.Base {}
            """)
        }
        test("known non-XCTest parenthesized aliases pass while uncertain ancestry stays refused") {
            let fixture = try world("ancestry-known", annotated: true)
            try fixture.register(fixture.run().derivedRegistrations)
            try fixture.write("Sources/A.swift", """
            @Suite(.productionAccessAudit) struct Example { @Test func body() {} }
            class PlainBase {}
            typealias Middle = (PlainBase)
            typealias Base = ((Middle))
            class Helper: Base { func testUtility() {} }
            """)
            let report = fixture.run()
            try report.encoded().write(to: fixture.root.appendingPathComponent("enforce-result.json"))
            try require(report.enforcementSatisfied, "known non-XCTest ancestry rejected")
            try rejectLegacy("ancestry-unknown", first:
                "typealias Base = (Unknown)\nclass Legacy: Base { func testAccess() {} }")
            try rejectLegacy("ancestry-restricted", first: "class PlainBase {}\nprivate typealias Base = (PlainBase)",
                             second: "class Legacy: Base { func testAccess() {} }")
            try rejectLegacy("ancestry-shadowed", first:
                "class PlainBase {}\ntypealias Base = (PlainBase)\nclass Legacy<Base>: Base { func testAccess() {} }")
        }
    }

    func dottedAncestryCases() {
        let globals = """
        import class XCTest.XCTestCase
        enum Names { class Base {} }
        enum Holder { typealias Base = XCTestCase }
        """
        test("nearer dotted namespace alias cannot hide an empty XCTest subclass") {
            try rejectLegacy("dotted-shadow", first: globals + """

            enum Outer { typealias Names = Holder; class Legacy: Names.Base {} }
            """)
        }
        test("nested alias chains cannot fall back to an unrelated global dotted ancestry") {
            try rejectLegacy("dotted-chain", first: globals + """

            enum Outer {
                typealias Middle = Holder
                typealias Names = Middle
                typealias Parent = Names.Base
                class Legacy: Parent {}
            }
            """)
        }
        test("cross-file dotted namespace shadowing rejects independently of declaration order") {
            let nested = "enum Outer { typealias Names = Holder; class Legacy: Names.Base {} }"
            try rejectLegacy("dotted-cross-file", first: globals, second: nested)
            for ordered in [[("A.swift", globals), ("B.swift", nested)],
                            [("B.swift", nested), ("A.swift", globals)]] {
                try rejects({ _ = try sourceReport(ordered) }, containing: "XCTest")
            }
        }
        test("restricted dotted namespace members cannot establish inaccessible ancestry bindings") {
            for access in ["private", "fileprivate"] {
                try rejectLegacy("dotted-\(access)", first: globals + """

                enum Outer { \(access) typealias Names = Holder }
                """, second: "extension Outer { class Legacy: Names.Base {} }")
            }
        }
        test("missing cyclic and ambiguous nearer namespace aliases never select a global member") {
            for (number, aliases) in [
                "typealias Names = Missing",
                "typealias Names = Loop; typealias Loop = Names",
                "typealias Names = Holder; typealias Names = Missing"
            ].enumerated() {
                try rejectLegacy("dotted-indeterminate-\(number)", first: globals +
                    "\nenum Outer { \(aliases); class Legacy: Names.Base {} }")
            }
        }
        test("known dotted member aliases and nearer nominal namespaces preserve non-XCTest helpers") {
            for (number, source) in [
                """
                enum Names { enum Group { class Base {} }; typealias Base = Group.Base }
                class Helper: Names.Base { func testUtility() {} }
                """,
                """
                enum Names { class Base {} }
                enum Outer {
                    enum Names { class Base {} }
                    class Helper: Names.Base { func testUtility() {} }
                }
                """
            ].enumerated() {
                let fixture = try world("dotted-known-\(number)", annotated: true)
                try fixture.register(fixture.run().derivedRegistrations)
                try fixture.write("Sources/A.swift",
                                  "@Suite(.productionAccessAudit) struct Example { @Test func body() {} }\n" + source)
                try require(fixture.run().enforcementSatisfied, "known dotted non-XCTest ancestry rejected")
            }
        }
        test("dotted namespace binding uses consistent conditional source variants") {
            let source = globals + """

            enum Outer {
            #if canImport(FluxKlangMac) && canImport(FoundationModels)
                typealias Names = Holder
            #else
                enum Names { class Base {} }
            #endif
                class Legacy: Names.Base {}
            }
            """
            for mac in [false, true] {
                for models in [false, true] {
                    if mac && models {
                        try rejects({
                            _ = try sourceReport([("A.swift", source)], macImport: mac, modelsImport: models)
                        }, containing: "XCTest")
                    } else {
                        let report = try sourceReport([("A.swift", source)], macImport: mac, modelsImport: models)
                        try require(report.exitCode == 0, "known conditional nominal namespace rejected")
                    }
                }
            }
        }
    }
}
#endif
