import Foundation
import SwiftSyntax

enum SourceAttributes {
    static func macro(_ attribute: AttributeSyntax) -> String? {
        let name = sourceTokens(attribute.attributeName).replacingOccurrences(of: " ", with: "")
        if ["Suite", "Testing.Suite"].contains(name) { return "Suite" }
        if ["Test", "Testing.Test"].contains(name) { return "Test" }
        return nil
    }

    static func validateName(_ attribute: AttributeSyntax) throws {
        if macro(attribute) != nil { return }
        let name = sourceTokens(attribute.attributeName).replacingOccurrences(of: " ", with: "")
        if ["Observable", "Observation.Observable"].contains(name) {
            // Standard Observation expansion produces observation helpers, not test declarations.
            // No custom names, arguments, or non-class application are inferred to be equivalent.
            try require(owningDeclaration(attribute)?.is(ClassDeclSyntax.self) == true,
                        "unsupported Observable declaration context")
            if let arguments = attribute.arguments {
                guard case .argumentList(let list) = arguments, list.isEmpty else {
                    throw AuditFailure("unsupported Observable arguments")
                }
            }
            return
        }
        let allowed = ["MainActor", "available", "testable", "Sendable", "TaskLocal", "discardableResult",
                       "inlinable", "usableFromInline", "inline", "preconcurrency", "escaping", "autoclosure",
                       "unchecked", "_transparent", "_alwaysEmitIntoClient", "_spi", "convention"]
        try require(allowed.contains(name), "unsupported/conflicting attribute macro: \(name)")
        try require(!hasAudit(attribute), "audit expression in non-Testing attribute")
    }

    private static func owningDeclaration(_ attribute: AttributeSyntax) -> Syntax? {
        var parent = attribute.parent
        // Only transparent attribute/conditional containers may be crossed.
        // Stop at the first declaration, never at a surrounding class.
        while let node = parent,
              [.attributeList, .ifConfigDecl, .ifConfigClause, .ifConfigClauseList].contains(node.kind) {
            parent = node.parent
        }
        return parent
    }

    static func hasAudit(_ node: some SyntaxProtocol) -> Bool {
        node.tokens(viewMode: .sourceAccurate).contains {
            if case .identifier = $0.tokenKind {
                return ["productionAccessAudit", "ProductionAccessScope"].contains(sourceName($0))
            }
            return false
        }
    }

}

struct AnnotationReview {
    var canonicalCount = 0
    var problems: [String] = []
    var unsupported: [String] = []

    mutating func inspect(_ attribute: AttributeSyntax) {
        guard let macro = SourceAttributes.macro(attribute) else { return }
        guard let arguments = attribute.arguments else { return }
        guard case .argumentList(let list) = arguments else {
            unsupported.append("unsupported Testing macro argument syntax")
            return
        }
        var parameters = false
        for argument in list {
            if argument.label?.text == "arguments" && macro == "Test" { parameters = true }
            let expression = argument.expression
            let canonical = Self.isCanonical(expression) && argument.label == nil && !parameters
            if canonical {
                canonicalCount += 1
            } else if SourceAttributes.hasAudit(expression) {
                problems.append("noncanonical/injected/nested audit expression")
            } else if parameters && (argument.label == nil || argument.label?.text == "arguments") {
                continue // Parameter values are not traits, and disabled tests are still indexed.
            } else if argument.label != nil || !Self.isAuxiliary(expression, macro: macro) {
                unsupported.append("unsupported opaque trait expression: \(sourceTokens(argument))")
            }
        }
    }

    private static func isCanonical(_ expression: ExprSyntax) -> Bool {
        guard let member = expression.as(MemberAccessExprSyntax.self) else { return false }
        return member.base == nil && member.declName.baseName.text == "productionAccessAudit" &&
            member.declName.argumentNames == nil
    }

    private static func isAuxiliary(_ expression: ExprSyntax, macro: String) -> Bool {
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            return literal.segments.allSatisfy { $0.is(StringSegmentSyntax.self) }
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return member.base == nil && member.declName.baseName.text == "serialized" &&
                member.declName.argumentNames == nil
        }
        guard let call = expression.as(FunctionCallExprSyntax.self), call.trailingClosure == nil,
              call.additionalTrailingClosures.isEmpty else { return false }
        // Explicit, independently reviewed auxiliary grammar; not registration evidence
        // and not an exemption for this constructor's file, tests, or owning root.
        if macro == "Suite", let name = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return name.baseName.text == "SuiteExitProbe" && name.argumentNames == nil && call.arguments.isEmpty
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base == nil,
              member.declName.argumentNames == nil else { return false }
        return ["timeLimit", "enabled", "disabled", "tags", "bug"].contains(member.declName.baseName.text)
    }
}
