import Foundation

struct TargetRole: Codable, Hashable {
    let target: String
    let role: String
}

struct QualificationIdentity: Codable, Hashable {
    let path: String
    let owner: String
    let signature: String
}

struct QualificationContract: Decodable {
    let target: String
    let tests: [QualificationIdentity]
}

// Deliberately not an exemption mechanism. V2 transcribes this one reviewed
// closure; it cannot introduce arbitrary target roles, sources or tests.
enum TargetRoleContract {
    static let target = "FluxKlangAppleQualificationTests"
    static let sharedFixture = "FluxKlangTests/AssistantRoutingFixture.swift"
    static let roles = [
        TargetRole(target: "FluxKlangTests", role: "audited"),
        TargetRole(target: "FluxKlangMacTests", role: "audited"),
        TargetRole(target: target, role: "appleQualification")
    ].sorted { $0.target < $1.target }
    static let tests = [
        QualificationIdentity(
            path: target + "/FoundationModelActionInterpreterLiveTests.swift",
            owner: "FoundationModelActionLiveTests",
            signature: "ownerRequestsUseAppleAndHostileLiveMetadataCannotAffectInterpretation ( ) async throws"),
        QualificationIdentity(
            path: target + "/AssistantRoutingChatTests.swift",
            owner: "AssistantRoutingChatTests",
            signature: "optInNativeOwnerAndPriorMonoQualification ( ) async throws")
    ]
    static let files = tests.map(\.path) + [sharedFixture]

    static func mainActor(_ identity: QualificationIdentity) -> Bool { identity == tests[1] }

    static func environment(_ identity: QualificationIdentity) -> String {
        identity == tests[0] ? "FLUXKLANG_RUN_APPLE_MODEL_TESTS" : "FLUXKLANG_QUALIFY_APPLE_ROUTING"
    }

    static func validate(_ manifest: AuditManifest) throws {
        try require(manifest.targetRoles?.count == roles.count && Set(manifest.targetRoles ?? []) == Set(roles),
                    "v2 requires the exact target roles")
        try require(manifest.qualification?.target == target &&
                    manifest.qualification?.tests.count == tests.count &&
                    Set(manifest.qualification?.tests ?? []) == Set(tests), "v2 qualification identities drift")
        let expected = roles.flatMap { role in
            ["Debug", "Release"].map {
                MatrixRow(target: role.target, module: role.target,
                          platform: role.target == "FluxKlangMacTests" ? "macOS" : "iOS", configuration: $0)
            }
        }
        try require(manifest.matrix.count == 6 && Set(manifest.matrix) == Set(expected),
                    "v2 requires the exact six target/module/platform/configuration rows")
        let sources = manifest.sources.filter { $0.target == target }
        try require(sources.count == 1 && sources[0].directories.isEmpty &&
                    sources[0].files.count == files.count && Set(sources[0].files) == Set(files),
                    "v2 qualification requires the exact explicit three-source closure")
    }

    static func validateMemberships(_ memberships: [String: [String]]) throws {
        try require(Set(memberships[target] ?? []) == Set(files), "qualification PBX closure drift")
        for name in ["FluxKlangTests", "FluxKlangMacTests"] {
            let members = Set(memberships[name] ?? [])
            try require(members.isDisjoint(with: tests.map(\.path)),
                        "qualification owner belongs to audited target: \(name)")
            try require(members.contains(sharedFixture) == (name == "FluxKlangTests"),
                        "shared qualification fixture audited membership drift: \(name)")
        }
    }
}

extension AuditChecker {
    static func inventory(
        manifest: AuditManifest, memberships: [String: [String]], parsed: [String: ParsedSource],
        report: inout AuditReport
    ) throws {
        var discovered: [SourceInventory] = []
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
                        if manifest.schemaVersion == 2 {
                            try SourceOwnership(inventory).validateDiscovery()
                            discovered.append(inventory)
                        } else {
                            let result = try SourceOwnership(inventory).analyze()
                            report.ownership += result.rows
                            report.diagnostics += result.diagnostics
                        }
                    } catch {
                        let scope = "\(matrix.target)/\(matrix.configuration)/\(variant.guardExpression)"
                        report.diagnostics.append(AuditDiagnostic(
                            category: "model", message: "\(scope): \(error)", registration: nil, site: nil))
                    }
                }
            }
        }
        guard manifest.schemaVersion == 2, report.diagnostics.isEmpty else { return }
        roleObligations(discovered, parsed: parsed, report: &report)
    }

    private static func roleObligations(
        _ discovered: [SourceInventory], parsed: [String: ParsedSource], report: inout AuditReport
    ) {
        for inventory in discovered {
            if inventory.variant.matrix.target == TargetRoleContract.target {
                let result = QualificationOwnership(inventory: inventory, parsed: parsed).analyze()
                report.qualification?.inventory += result.rows
                report.diagnostics += result.diagnostics
            } else {
                do {
                    let result = try SourceOwnership(inventory).analyze()
                    report.ownership += result.rows
                    report.diagnostics += result.diagnostics
                } catch {
                    report.diagnostics.append(AuditDiagnostic(
                        category: "model", message: String(describing: error), registration: nil, site: nil))
                }
            }
        }
    }
}
