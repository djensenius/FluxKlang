import Foundation
import SwiftSyntax

struct QualificationRow: Codable {
    let target: String
    let module: String
    let path: String
    let owner: String
    let ownerKind: String
    let signature: String
    let configuration: String
    let guardExpression: String
    let ownerLine: Int
    let methodLine: Int
    let mainActor: Bool
    let optInEnvironment: String

    var sortKey: String {
        [target, configuration, guardExpression, path, owner, signature].joined(separator: "\u{1F}")
    }
}

struct QualificationReport: Codable {
    var contractSatisfied = false
    var inventory: [QualificationRow] = []

    var textLines: [String] {
        ["qualification contractSatisfied=\(contractSatisfied) inventory=\(inventory.count)"] + inventory.map {
            "qualification \($0.sortKey) ownerKind=\($0.ownerKind) ownerLine=\($0.ownerLine) " +
                "methodLine=\($0.methodLine) mainActor=\($0.mainActor) optInEnvironment=\($0.optInEnvironment)"
        }
    }
}

struct QualificationOwnership {
    let inventory: SourceInventory
    let parsed: [String: ParsedSource]

    func analyze() -> (rows: [QualificationRow], diagnostics: [AuditDiagnostic]) {
        var rows: [QualificationRow] = []
        var site: SourceSite?
        do {
            for path in TargetRoleContract.files {
                guard let source = parsed[path] else { throw AuditFailure("missing qualification source: \(path)") }
                try rejectConditionals(Syntax(source.tree), source: source)
            }
            site = inventory.misplaced.first ?? inventory.functions.first?.site
            try require(inventory.misplaced.isEmpty, "misplaced qualification Testing/audit annotation")
            try require(inventory.functions.count == 2, "qualification requires exactly two test methods")
            for nominal in inventory.nominals {
                site = nominal.site
                try require(!nominal.attributes.contains {
                    SourceAttributes.macro($0) != nil || SourceAttributes.hasAudit($0)
                }, "qualification disallows Suite/audit traits")
            }
            for extended in inventory.extensions {
                site = extended.site
                try require(!extended.attributes.contains {
                    SourceAttributes.macro($0) != nil || SourceAttributes.hasAudit($0)
                }, "qualification disallows extension Testing/audit traits")
            }
            for identity in TargetRoleContract.tests {
                site = nil
                let matches = inventory.nominals.enumerated().filter {
                    $0.element.parent == nil && $0.element.site.path == identity.path &&
                        $0.element.site.name == identity.owner
                }
                try require(matches.count == 1, "missing/ambiguous top-level qualification owner: \(identity.owner)")
                guard let match = matches.first else { throw AuditFailure("missing qualification owner") }
                let nominal = match.element
                site = nominal.site
                try validateExtensions(owner: match.offset)
                guard let owner = nominal.declaration.as(StructDeclSyntax.self) else {
                    throw AuditFailure("qualification owner must be a struct")
                }
                try require(!nominal.unsupported && owner.modifiers.isEmpty &&
                            sourceTokens(owner.attributes) ==
                                (TargetRoleContract.mainActor(identity) ? "@ MainActor" : ""),
                            "qualification owner actor/attributes/signature drift")
                // Match the actual declaring nominal index AND the direct syntax
                // child identity. Flattened root names cannot authorize substitutions.
                let methods = inventory.functions.filter { $0.parent == .nominal(match.offset) }
                try require(methods.count == 1 && owner.memberBlock.members.count == 1,
                            "qualification owner requires only its directly declared approved method")
                guard let method = methods.first,
                      let direct = owner.memberBlock.members.first?.decl.as(FunctionDeclSyntax.self),
                      direct.id == method.declaration.id else {
                    throw AuditFailure("qualification method is not the direct owner declaration")
                }
                site = method.site
                try validate(method, identity: identity)
                let matrix = inventory.variant.matrix
                rows.append(QualificationRow(
                    target: matrix.target, module: matrix.module, path: identity.path, owner: identity.owner,
                    ownerKind: "struct", signature: identity.signature, configuration: matrix.configuration,
                    guardExpression: inventory.variant.guardExpression, ownerLine: nominal.site.line,
                    methodLine: method.site.line, mainActor: TargetRoleContract.mainActor(identity),
                    optInEnvironment: TargetRoleContract.environment(identity)))
            }
            return (rows, [])
        } catch let failure as QualificationFailure {
            return ([], [diagnostic(failure.message, site: failure.site)])
        } catch {
            return ([], [diagnostic(String(describing: error), site: site)])
        }
    }

    private func validate(_ method: FunctionRecord, identity: QualificationIdentity) throws {
        let declaration = method.declaration
        try require(method.site.path == identity.path && method.site.name == identity.signature &&
                    declaration.modifiers.isEmpty && declaration.genericParameterClause == nil &&
                    declaration.genericWhereClause == nil && declaration.body != nil,
                    "qualification method signature/modifier drift")
        let flag = TargetRoleContract.environment(identity)
        let expected = "@ Test ( . enabled ( if : ProcessInfo . processInfo . environment " +
            "[ \" \(flag) \" ] == \" 1 \" ) )"
        try require(sourceTokens(declaration.attributes) == expected,
                    "qualification requires the single exact Test opt-in expression and no extra traits")
    }

    private func validateExtensions(owner: Int) throws {
        let bindings = SourceExtensionOwnership(inventory)
        for number in inventory.extensions.indices {
            // An unresolved/alias/constrained target cannot establish that an
            // extension leaves the approved owner's one-method contract intact.
            guard let target = bindings.extensionTarget(number) else {
                throw QualificationFailure(message: "indeterminate qualification extension owner",
                                           site: inventory.extensions[number].site)
            }
            if target == owner {
                throw QualificationFailure(message: "qualification owner cannot acquire extension members",
                                           site: inventory.extensions[number].site)
            }
        }
    }

    private func rejectConditionals(_ node: Syntax, source: ParsedSource) throws {
        if node.is(IfConfigDeclSyntax.self) {
            throw QualificationFailure(
                message: "conditional compilation is unsupported in qualification sources",
                site: SourceSite(path: source.path,
                                 line: source.converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
                                 name: "#if"))
        }
        for child in node.children(viewMode: .sourceAccurate) { try rejectConditionals(child, source: source) }
    }

    private func diagnostic(_ message: String, site: SourceSite?) -> AuditDiagnostic {
        let variant = inventory.variant
        return AuditDiagnostic(
            category: "qualification",
            message: "\(variant.matrix.target)/\(variant.matrix.configuration)/\(variant.guardExpression): \(message)",
            registration: nil, site: site)
    }
}

private struct QualificationFailure: Error {
    let message: String
    let site: SourceSite
}
