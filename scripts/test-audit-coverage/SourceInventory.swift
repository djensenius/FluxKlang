import Foundation
import SwiftParser
import SwiftSyntax

struct SourceVariant {
    let matrix: MatrixRow
    let macImport: Bool
    let modelsImport: Bool

    var guardExpression: String {
        "canImport(FluxKlangMac)=\(macImport)&&canImport(FoundationModels)=\(modelsImport)"
    }

    static var guards: Set<String> {
        Set([false, true].flatMap { mac in
            [false, true].map { models in
                "canImport(FluxKlangMac)=\(mac)&&canImport(FoundationModels)=\(models)"
            }
        })
    }

    var atoms: [String: Bool] {
        ["true": true, "false": false, "DEBUG": matrix.configuration == "Debug",
         "os(iOS)": matrix.platform == "iOS", "os(macOS)": matrix.platform == "macOS",
         "canImport(FluxKlangMac)": macImport, "canImport(FoundationModels)": modelsImport]
    }
}

// SwiftParser supplies tokens; this deliberately tiny Boolean language does not
// infer SDK availability. Both canImport bits have ONE assignment across all files.
struct SourceCondition {
    let tokens: [String]
    let atoms: [String: Bool]
    var offset = 0

    mutating func evaluate() throws -> Bool {
        let result = try disjunction()
        try require(offset == tokens.count, "unsupported conditional expression: \(tokens.joined())")
        return result
    }

    mutating func take(_ token: String) -> Bool {
        guard offset < tokens.count && tokens[offset] == token else { return false }
        offset += 1
        return true
    }

    private mutating func disjunction() throws -> Bool {
        var result = try conjunction()
        while take("||") {
            let right = try conjunction()
            result = result || right
        }
        return result
    }

    private mutating func conjunction() throws -> Bool {
        var result = try primary()
        while take("&&") {
            let right = try primary()
            result = result && right
        }
        return result
    }

    private mutating func primary() throws -> Bool {
        if take("!") { return try !primary() }
        if take("(") {
            let value = try disjunction()
            try require(take(")"), "conditional closing parenthesis expected")
            return value
        }
        try require(offset < tokens.count, "conditional atom expected")
        var name = tokens[offset]
        offset += 1
        if ["os", "canImport"].contains(name) {
            try require(take("(") && offset < tokens.count, "conditional argument expected")
            name += "(" + tokens[offset] + ")"
            offset += 1
            try require(take(")"), "unsupported conditional call")
        }
        guard let value = atoms[name] else { throw AuditFailure("unsupported conditional atom: \(name)") }
        return value
    }
}

func sourceName(_ token: TokenSyntax) -> String {
    token.text.replacingOccurrences(of: "`", with: "")
}

func sourceTokens(_ node: some SyntaxProtocol) -> String {
    node.tokens(viewMode: .sourceAccurate).map(\.text).joined(separator: " ")
}

enum OwnerContext: Hashable {
    case nominal(Int)
    case extended(Int)
    case local
}

struct SourceSite: Codable, Hashable {
    let path: String
    let line: Int
    let name: String
}

struct NominalRecord {
    let site: SourceSite
    let qualified: String?
    let parent: OwnerContext?
    let restricted: Bool
    let unsupported: Bool
    let isClass: Bool
    let bases: [String?]
    let baseTypes: [TypeSyntax]
    let genericParameters: Set<String>
    let attributes: [AttributeSyntax]
}

struct TypeAliasRecord {
    let site: SourceSite
    let qualified: String?
    let parent: OwnerContext?
    let restricted: Bool
    let target: String?
    let value: TypeSyntax?
    let ancestryType: TypeSyntax
    let genericParameters: Set<String>
}

struct LegacyFunctionRecord {
    let site: SourceSite
    let parent: OwnerContext
    let declaration: FunctionDeclSyntax
}

struct ExtensionRecord {
    let site: SourceSite
    let qualified: String?
    let restricted: Bool
    let unsupported: Bool
    let attributes: [AttributeSyntax]
}

struct FunctionRecord {
    let site: SourceSite
    let parent: OwnerContext?
    let unsupported: Bool
    let attributes: [AttributeSyntax]
}

struct ParsedSource {
    let path: String
    let tree: SourceFileSyntax
    let converter: SourceLocationConverter

    init(path: String, text: String) throws {
        try require(text.utf8.count <= 8_000_000, "source size limit: \(path)")
        self.path = path
        tree = Parser.parse(source: text)
        try require(!tree.hasError, "Swift syntax recovery/error: \(path)")
        converter = SourceLocationConverter(fileName: path, tree: tree)
        try preflight(Syntax(tree))
    }

    private func preflight(_ node: Syntax) throws {
        if let condition = node.as(IfConfigClauseSyntax.self)?.condition {
            let row = MatrixRow(target: "", module: "", platform: "iOS", configuration: "Debug")
            var parser = SourceCondition(tokens: condition.tokens(viewMode: .sourceAccurate).map(\.text),
                                         atoms: SourceVariant(matrix: row, macImport: false, modelsImport: false).atoms)
            _ = try parser.evaluate()
        }
        try require(!node.is(MacroDeclSyntax.self) && !node.is(MacroExpansionDeclSyntax.self),
                    "unsupported declaration-producing macro: \(path)")
        if let macro = node.as(MacroExpansionExprSyntax.self) {
            try require(["expect", "require", "file", "fileID", "filePath", "line", "column", "function",
                         "isolation", "dsohandle", "selector", "keyPath", "_sourceLocation"]
                .contains(macro.macroName.text),
                        "unsupported expression/declaration macro: \(path): \(macro.macroName.text)")
            if macro.macroName.text == "_sourceLocation" {
                try require(macro.arguments.isEmpty && macro.trailingClosure == nil &&
                            macro.additionalTrailingClosures.isEmpty && macro.genericArgumentClause == nil,
                            "unsupported Testing source-location macro arguments")
            }
        }
        if let attribute = node.as(AttributeSyntax.self) { try SourceAttributes.validateName(attribute) }
        for child in node.children(viewMode: .all) { try preflight(child) }
    }
}

struct SourceInventory {
    let variant: SourceVariant
    var nominals: [NominalRecord] = []
    var extensions: [ExtensionRecord] = []
    var functions: [FunctionRecord] = []
    var misplaced: [SourceSite] = []
    var aliases: [TypeAliasRecord] = []
    var legacyFunctions: [LegacyFunctionRecord] = []

    mutating func add(_ source: ParsedSource) throws {
        try walk(Syntax(source.tree), context: nil, source: source)
    }

    private func attributes(_ list: AttributeListSyntax) throws -> [AttributeSyntax] {
        var result: [AttributeSyntax] = []
        for element in list {
            if let attribute = element.as(AttributeSyntax.self) { result.append(attribute) }
            if let conditional = element.as(IfConfigDeclSyntax.self), let active = try activeClause(conditional) {
                if let list = active.elements?.as(AttributeListSyntax.self) { result += try attributes(list) }
            }
        }
        return result
    }

    private func activeClause(_ conditional: IfConfigDeclSyntax) throws -> IfConfigClauseSyntax? {
        for clause in conditional.clauses {
            guard let condition = clause.condition else { return clause }
            var parser = SourceCondition(tokens: condition.tokens(viewMode: .sourceAccurate).map(\.text),
                                         atoms: variant.atoms)
            if try parser.evaluate() { return clause }
        }
        return nil
    }

    private func site(_ node: Syntax, name: String, source: ParsedSource) -> SourceSite {
        let line = source.converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        return SourceSite(path: source.path, line: line,
                   name: name)
    }

    private func prefix(_ context: OwnerContext?) -> String? {
        switch context {
        case .none: return ""
        case .nominal(let index): return nominals[index].qualified
        case .extended(let index): return extensions[index].qualified
        case .local: return nil
        }
    }

    private func restricted(_ context: OwnerContext?) -> Bool {
        if case .nominal(let index) = context { return nominals[index].restricted }
        if case .extended(let index) = context { return extensions[index].restricted }
        return false
    }

    private mutating func walk(_ node: Syntax, context: OwnerContext?, source: ParsedSource) throws {
        if let conditional = node.as(IfConfigDeclSyntax.self) {
            if let clause = try activeClause(conditional), let elements = clause.elements {
                try walk(Syntax(elements), context: context, source: source)
            }
            return
        }
        if let extended = node.as(ExtensionDeclSyntax.self) {
            try addExtension(extended, context: context, source: source)
            return
        }
        if let group = node.asProtocol(DeclGroupSyntax.self),
           let named = node.asProtocol(NamedDeclSyntax.self) {
            try addNominal(node, group: group, name: sourceName(named.name), context: context, source: source)
            return
        }
        if let function = node.as(FunctionDeclSyntax.self) {
            try addFunction(function, context: context, source: source)
            return
        }
        if let alias = node.as(TypeAliasDeclSyntax.self) {
            let name = sourceName(alias.name)
            let qualified = prefix(context).map { $0.isEmpty ? name : $0 + "." + name }
            let isPrivate = alias.modifiers.contains { ["private", "fileprivate"].contains($0.name.text) }
            aliases.append(TypeAliasRecord(
                site: site(node, name: name, source: source), qualified: qualified, parent: context,
                restricted: isPrivate || restricted(context),
                target: alias.genericParameterClause == nil ? Self.ancestryName(alias.initializer.value) : nil,
                value: alias.genericParameterClause == nil ? alias.initializer.value : nil,
                ancestryType: alias.initializer.value,
                genericParameters: Self.genericNames(alias.genericParameterClause)))
        }
        if node.is(DeclSyntax.self), let attributed = node.asProtocol(WithAttributesSyntax.self) {
            let attrs = try attributes(attributed.attributes)
            if attrs.contains(where: { SourceAttributes.macro($0) != nil || SourceAttributes.hasAudit($0) }) {
                misplaced.append(site(node, name: "unsupported annotation placement", source: source))
            }
        }
        let nestedContext: OwnerContext? = node.is(ExprSyntax.self) || node.is(StmtSyntax.self) ||
            node.is(AccessorDeclSyntax.self) || node.is(InitializerDeclSyntax.self) ||
            node.is(DeinitializerDeclSyntax.self) ? .local : context
        for child in node.children(viewMode: .sourceAccurate) {
            try walk(child, context: nestedContext, source: source)
        }
    }

    private mutating func addFunction(
        _ function: FunctionDeclSyntax, context: OwnerContext?, source: ParsedSource
    ) throws {
        if Self.testShaped(function), let context, context != .local {
            legacyFunctions.append(LegacyFunctionRecord(
                site: site(Syntax(function), name: sourceName(function.name), source: source),
                parent: context, declaration: function))
        }
        let attrs = try attributes(function.attributes)
        if attrs.contains(where: { SourceAttributes.macro($0) != nil }) {
            let opaque = function.signature.parameterClause.parameters.contains { Self.opaqueType(Syntax($0.type)) } ||
                function.signature.returnClause.map { Self.opaqueType(Syntax($0.type)) } == true
            let generic = function.genericParameterClause != nil || function.genericWhereClause != nil || opaque
            let name = sourceName(function.name) + " " + sourceTokens(function.signature)
            functions.append(FunctionRecord(site: site(Syntax(function), name: name, source: source), parent: context,
                                            unsupported: generic, attributes: attrs))
        }
        for child in function.children(viewMode: .sourceAccurate) {
            try walk(child, context: .local, source: source)
        }
    }

    private mutating func addNominal(
        _ node: Syntax, group: any DeclGroupSyntax, name: String, context: OwnerContext?, source: ParsedSource
    ) throws {
        let supported = node.is(StructDeclSyntax.self) || node.is(ClassDeclSyntax.self) ||
            node.is(EnumDeclSyntax.self) || node.is(ActorDeclSyntax.self)
        let generic = node.asProtocol(WithGenericParametersSyntax.self)?.genericParameterClause != nil
        let qualified = prefix(context).map { $0.isEmpty ? name : $0 + "." + name }
        let isPrivate = group.modifiers.contains { ["private", "fileprivate"].contains($0.name.text) }
        let record = NominalRecord(
            site: site(node, name: name, source: source), qualified: qualified, parent: context,
            restricted: isPrivate || restricted(context),
            unsupported: !supported || generic || group.genericWhereClause != nil || group.inheritanceClause != nil,
            isClass: node.is(ClassDeclSyntax.self),
            bases: group.inheritanceClause?.inheritedTypes.map { Self.ancestryName($0.type) } ?? [],
            baseTypes: group.inheritanceClause?.inheritedTypes.map(\.type) ?? [],
            genericParameters: Self.genericNames(node.asProtocol(WithGenericParametersSyntax.self)?
                .genericParameterClause),
            attributes: try attributes(group.attributes))
        let index = nominals.count
        nominals.append(record)
        try walk(Syntax(group.attributes), context: .local, source: source)
        try walk(Syntax(group.memberBlock.members), context: .nominal(index), source: source)
    }

    private mutating func addExtension(
        _ extended: ExtensionDeclSyntax, context: OwnerContext?, source: ParsedSource
    ) throws {
        let qualified = Self.typeName(extended.extendedType)
        let isPrivate = extended.modifiers.contains { ["private", "fileprivate"].contains($0.name.text) }
        let record = ExtensionRecord(
            site: site(Syntax(extended), name: qualified ?? "<unsupported extended type>", source: source),
            qualified: qualified,
            restricted: isPrivate || restricted(context),
            unsupported: context != nil || extended.genericWhereClause != nil || extended.inheritanceClause != nil,
            attributes: try attributes(extended.attributes))
        let index = extensions.count
        extensions.append(record)
        try walk(Syntax(extended.attributes), context: .local, source: source)
        try walk(Syntax(extended.memberBlock.members), context: .extended(index), source: source)
    }

    private static func opaqueType(_ node: Syntax) -> Bool {
        if let type = node.as(SomeOrAnyTypeSyntax.self),
           type.someOrAnySpecifier.tokenKind == .keyword(.some) { return true }
        return node.children(viewMode: .sourceAccurate).contains { opaqueType($0) }
    }

    static func ancestryName(_ type: TypeSyntax) -> String? {
        if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
           let element = tuple.elements.first, element.firstName == nil,
           element.secondName == nil, element.ellipsis == nil {
            return ancestryName(element.type)
        }
        return typeName(type)
    }

    static func typeName(_ type: TypeSyntax) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            return sourceName(identifier.name)
        }
        if let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil,
           let base = typeName(member.baseType) {
            return base + "." + sourceName(member.name)
        }
        return nil
    }

    private static func testShaped(_ function: FunctionDeclSyntax) -> Bool {
        // Return types are classified only after all active files have been indexed.
        sourceName(function.name).hasPrefix("test") && function.signature.parameterClause.parameters.isEmpty &&
            !function.modifiers.contains(where: { ["static", "class"].contains($0.name.text) })
    }

    static func genericNames(_ clause: GenericParameterClauseSyntax?) -> Set<String> {
        Set(clause?.parameters.map { sourceName($0.name) } ?? [])
    }
}

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
