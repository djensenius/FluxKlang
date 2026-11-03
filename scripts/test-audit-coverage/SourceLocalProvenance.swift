import SwiftSyntax

// Rejection-only lexical presence, never local Swift name/alias resolution.
// IDs belong to one active-variant inventory; separate files have separate roots.
final class SourceLocalProvenance {
    enum Record: Hashable { case nominal(Int), alias(Int), extended(Int) }
    enum Presence { case nonlocal, absent, formal, declaration, indeterminate }
    struct LookupContext {
        let inventory: SourceInventory
        let bindings: SourceExtensionOwnership
        let path: String
    }
    private enum Kind { case file, nominal, alias, function, closure, block, extended }
    private enum DeclarationKind { case nominal, alias, other }
    private struct Region {
        let path: String
        let start: Int
        let end: Int
    }
    private struct Scope {
        let parent: Int?
        let region: Region
        let kind: Kind
        let local: Bool
        let formals: Set<String>
    }
    private struct Declaration {
        let region: Region
        let scope: Int
        let name: String
        let kind: DeclarationKind
    }
    private struct Key: Hashable {
        let scope: Int
        let name: String
    }
    private struct ContextKey: Hashable {
        let key: Key
        let path: String
        let index: ObjectIdentifier
    }

    private var scopes: [Scope] = []
    private var declarations: [Declaration] = []
    private var names: [Key: [Int]] = [:]
    private var records: [Record: Int] = [:]
    private var owners: [Int: Record] = [:]
    private var expectedOwners = 0
    private var associationsComplete = false
    private var completed: [ContextKey: Presence] = [:]
    private var finalized = false

    // Called by the existing walk only after conditional selection. Transparent
    // syntax and conditional containers do not introduce lexical scopes.
    func enter(_ node: Syntax, parent: Int?, source: ParsedSource) throws -> Int? {
        try require(!finalized, "local provenance changed after finalization")
        let region = Region(path: source.path, start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                            end: node.endPositionBeforeTrailingTrivia.utf8Offset)
        if let named = node.asProtocol(NamedDeclSyntax.self), let parent {
            let kind: DeclarationKind = node.is(TypeAliasDeclSyntax.self) ? .alias :
                (node.asProtocol(DeclGroupSyntax.self) != nil ? .nominal : .other)
            let name = sourceName(named.name)
            let identity = declarations.count
            declarations.append(Declaration(region: region, scope: parent, name: name, kind: kind))
            names[Key(scope: parent, name: name), default: []].append(identity)
        }
        guard let kind = scopeKind(node) else { return parent }
        if kind == .nominal || kind == .extended { expectedOwners += 1 }
        let local = parent.map { scopes[$0].local } == true ||
            [.function, .closure, .block].contains(kind)
        let formals = SourceInventory.genericNames(node.asProtocol(WithGenericParametersSyntax.self)?
            .genericParameterClause)
        let identity = scopes.count
        scopes.append(Scope(parent: parent, region: region, kind: kind, local: local, formals: formals))
        return identity
    }

    private func scopeKind(_ node: Syntax) -> Kind? {
        if node.is(SourceFileSyntax.self) { return .file }
        if node.is(ExtensionDeclSyntax.self) { return .extended }
        if node.asProtocol(DeclGroupSyntax.self) != nil { return .nominal }
        if node.is(TypeAliasDeclSyntax.self) { return .alias }
        if node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self) ||
            node.is(DeinitializerDeclSyntax.self) || node.is(AccessorDeclSyntax.self) { return .function }
        if node.is(ClosureExprSyntax.self) { return .closure }
        if node.is(CodeBlockSyntax.self) || node.is(SwitchCaseSyntax.self) { return .block }
        return nil
    }

    func bind(_ record: Record, scope: Int?) throws {
        try require(!finalized && records[record] == nil, "duplicate/finalized local provenance record")
        guard let scope else { throw AuditFailure("missing local provenance scope") }
        if case .alias = record {
            records[record] = scope
            return
        }
        try require(owners[scope] == nil, "duplicate local provenance owner association")
        owners[scope] = record
        records[record] = scope
    }

    func finalize() {
        finalized = true
        associationsComplete = owners.count == expectedOwners
    }

    func presence(
        _ path: String, record: Record, context: LookupContext, members: (String, Int) -> [Int]?
    ) -> Presence {
        guard finalized && associationsComplete, context.inventory.localProvenance === self,
              let scope = records[record], scopes[scope].region.path == context.path,
              let first = path.split(separator: ".").first.map(String.init) else { return .indeterminate }
        guard scopes[scope].local else { return .nonlocal }
        let key = Key(scope: scope, name: first)
        let cacheKey = ContextKey(key: key, path: context.path, index: ObjectIdentifier(context.bindings))
        if let value = completed[cacheKey] { return value }
        let value = search(key, context: context, members: members)
        completed[cacheKey] = value
        return value
    }

    private func search(_ key: Key, context: LookupContext, members: (String, Int) -> [Int]?) -> Presence {
        var current: Int? = key.scope
        while let identity = current {
            let scope = scopes[identity]
            // A lexical search must not become module/global binding. Physical
            // absence is incomplete until associated visibility is consulted.
            if scope.kind == .file { return .absent }
            if scope.formals.contains(key.name) { return .formal }
            // Starting inheritance sees formals, but neither physical nor
            // associated members of its own body.
            if identity != key.scope {
                let value = scopedPresence(Key(scope: identity, name: key.name), context: context, members: members)
                switch value {
                case .absent: break
                default: return value
                }
            }
            // Never walk the resolved target's lexical nominal parents.
            if scope.kind == .extended { return .absent }
            current = scope.parent
        }
        return .absent
    }

    private func scopedPresence(_ key: Key, context: LookupContext, members: (String, Int) -> [Int]?) -> Presence {
        let owner = owners[key.scope]
        var target: Int?
        if case .extended(let number) = owner {
            target = context.bindings.extensionTarget(number)
            if let target, context.inventory.nominals[target].genericParameters.contains(key.name) { return .formal }
        }
        if let physical = physicalPresence(key) { return physical }
        switch owner {
        case .nominal(let number):
            let nominal = context.inventory.nominals[number]
            // Purely local baseless owners have no extra inherited/extension
            // visibility to consult; lack of global identity is not a refusal.
            if nominal.qualified == nil && nominal.bases.isEmpty { return .absent }
            return memberPresence(members(key.name, number))
        case .extended:
            guard let target else { return .indeterminate }
            return memberPresence(members(key.name, target))
        case .alias: return .indeterminate
        case .none: return .absent
        }
    }

    private func physicalPresence(_ key: Key) -> Presence? {
        let candidates = names[key] ?? []
        guard !candidates.isEmpty else { return nil }
        guard candidates.count == 1, declarations[candidates[0]].kind != .other else { return .indeterminate }
        return .declaration
    }

    private func memberPresence(_ candidates: [Int]?) -> Presence {
        guard let candidates, candidates.count <= 1 else { return .indeterminate }
        // No consumed alias initializer, namespace tail, or lineage query.
        return candidates.isEmpty ? .absent : .declaration
    }
}
