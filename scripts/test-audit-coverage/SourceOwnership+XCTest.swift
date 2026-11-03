import SwiftSyntax

// This is a rejection guard, not XCTest discovery or general Swift semantic
// resolution. Unknown/ambiguous ancestry is never evidence that a test-shaped
// inherited class is a helper. Plain helpers without discovery-shaped members
// remain valid unless their supported ancestry actually reaches XCTestCase.
final class XCTestDiscoveryGuard {
    enum Lineage { case ordinary, xctest, unknown }
    private enum BaseBinding {
        case resolved([Int])
        case indeterminate

        var choices: [Int]? {
            if case .resolved(let value) = self { return value }
            return nil
        }
    }
    struct Node {
        let site: SourceSite
        let qualified: String?
        let restricted: Bool
        let parent: OwnerContext?
        let bases: [String?]
        let baseTypes: [TypeSyntax]
    }

    let inventory: SourceInventory
    let nodes: [Node]
    private let bindings: SourceExtensionOwnership
    private var baseBindings: [Int: [String: BaseBinding]] = [:]
    private var validatedAncestry: Set<Int> = []
    private var activeAncestry: Set<Int> = []
    private var lineages: [Int: Lineage] = [:]
    private var activeLineage: Set<Int> = []
    private var cyclicLineage: Set<Int> = []

    init(_ inventory: SourceInventory, bindings: SourceExtensionOwnership) {
        self.inventory = inventory
        self.bindings = bindings
        nodes = inventory.nominals.map {
            Node(site: $0.site, qualified: $0.qualified, restricted: $0.restricted,
                 parent: $0.parent, bases: $0.isClass ? $0.bases : [],
                 baseTypes: $0.isClass ? $0.baseTypes : [])
        } + inventory.aliases.map {
            Node(site: $0.site, qualified: $0.qualified, restricted: $0.restricted,
                 parent: $0.parent, bases: [$0.target], baseTypes: [$0.ancestryType])
        }
    }

    func validate() throws {
        var shaped = Set<OwnerContext>()
        for function in inventory.legacyFunctions {
            let parameters = SourceInventory.genericNames(function.declaration.genericParameterClause)
            let scope = returnScope(site: function.site, context: function.parent,
                                    parameters: parameters)
            if !definitelyNonVoid(function.declaration.signature.returnClause?.type, scope: scope, visiting: []) {
                shaped.insert(function.parent)
            }
        }
        for (number, extended) in inventory.extensions.enumerated() where shaped.contains(.extended(number)) {
            guard let owner = bindings.extensionTarget(number) else {
                throw AuditFailure("unresolved XCTest-shaped extension ownership: \(extended.site)")
            }
            try require(lineage(owner) == .ordinary,
                        "unsupported XCTest-shaped extension ancestry: \(extended.site)")
            if owner < inventory.nominals.count { shaped.insert(.nominal(owner)) }
        }
        for (number, nominal) in inventory.nominals.enumerated() where nominal.isClass {
            try validateAncestryBindings(number)
            let ancestry = lineage(number)
            try require(ancestry != .xctest, "unsupported XCTest discovery-bearing class: \(nominal.site)")
            if !nominal.bases.isEmpty && shaped.contains(.nominal(number)) {
                try require(ancestry == .ordinary,
                            "unresolved/ambiguous XCTest-shaped class ancestry: \(nominal.site)")
            }
        }
    }
}

extension XCTestDiscoveryGuard {
    private func lookup(_ name: String?, path: String, scope: String) -> [Int]? {
        bindings.lexical(name, path: path, scope: scope)
    }

    private struct ReturnScope {
        let path: String
        let parameters: Set<String>
        let context: OwnerContext?
    }

    private func returnScope(
        site: SourceSite, context: OwnerContext?, parameters: Set<String> = []
    ) -> ReturnScope {
        switch context {
        case .nominal(let index):
            let nominal = inventory.nominals[index]
            let outer = returnScope(site: site, context: nominal.parent)
            return ReturnScope(path: site.path,
                               parameters: parameters.union(nominal.genericParameters).union(outer.parameters),
                               context: context)
        case .extended(let index):
            let owner = bindings.extensionTarget(index)
            let inherited = owner.map { parameters.union(returnScope(site: site, context: .nominal($0)).parameters) }
                ?? parameters
            return ReturnScope(path: site.path, parameters: inherited, context: context)
        case .none, .local:
            return ReturnScope(path: site.path, parameters: parameters, context: context)
        }
    }

    // This is a bounded proof of NON-Void, not Swift type checking. Both Void and
    // indeterminate returns remain discovery candidates. Aliases are resolved in
    // their declaration scope within this target's single consistent variant.
    private func definitelyNonVoid(_ type: TypeSyntax?, scope: ReturnScope, visiting: Set<Int>) -> Bool {
        guard let type else { return false }
        if let tuple = type.as(TupleTypeSyntax.self) {
            if tuple.elements.count > 1 { return true }
            guard let element = tuple.elements.first, element.firstName == nil,
                  element.secondName == nil, element.ellipsis == nil else { return false }
            return definitelyNonVoid(element.type, scope: scope, visiting: visiting)
        }
        if [.optionalType, .implicitlyUnwrappedOptionalType, .arrayType, .dictionaryType,
            .functionType, .metatypeType].contains(type.kind) { return true }
        return namedNonVoid(type, scope: scope, visiting: visiting)
    }

    private func namedNonVoid(_ type: TypeSyntax, scope: ReturnScope, visiting: Set<Int>) -> Bool {
        guard let name = SourceInventory.typeName(type),
              let first = name.split(separator: ".").first.map(String.init),
              !scope.parameters.contains(first) else { return false }
        // A lexical/global spelling is not proof while an inherited binding could
        // shadow its first component, including a source nominal or module name.
        guard let firstChoices = scopedChoices(first, path: scope.path, context: scope.context),
              let choices = qualifiedChoices(name, first: firstChoices, path: scope.path) else { return false }
        if !choices.isEmpty {
            guard choices.count == 1, let choice = choices.first, !visiting.contains(choice) else { return false }
            if choice < inventory.nominals.count { return true }
            let alias = inventory.aliases[choice - inventory.nominals.count]
            if case .local = alias.parent { return false }
            return definitelyNonVoid(alias.value, scope: returnScope(site: alias.site, context: alias.parent),
                                     visiting: visiting.union([choice]))
        }
        // Do not reinterpret a source namespace named Swift as the standard module.
        guard firstChoices.isEmpty else { return false }
        let primitives = ["Bool", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16",
                          "UInt32", "UInt64", "String", "Character", "Float", "Double", "Never"]
        return primitives.contains(name) || primitives.contains { name == "Swift." + $0 }
    }

    // nil means indeterminate, [] means absence proved within the supported
    // source model. Never fall through an unknown base to a global/builtin name.
    private func scopedChoices(_ name: String, path: String, context: OwnerContext?) -> [Int]? {
        switch context {
        case .nominal(let number):
            guard let members = memberChoices(name, owner: number, path: path, visiting: []) else { return nil }
            if !members.isEmpty { return members }
            return scopedChoices(name, path: path, context: inventory.nominals[number].parent)
        case .extended(let number):
            guard let owner = bindings.extensionTarget(number),
                  let members = memberChoices(name, owner: owner, path: path, visiting: []) else { return nil }
            if !members.isEmpty { return members }
            return exactChoices(name, path: path)
        case .none: return exactChoices(name, path: path)
        case .local: return nil
        }
    }

    private func exactChoices(_ name: String, path: String) -> [Int]? {
        bindings.exact(name, path: path)
    }

    private func qualifiedChoices(_ name: String, first: [Int], path: String) -> [Int]? {
        if first.isEmpty { return [] }
        var choices = first
        for component in name.split(separator: ".").dropFirst() {
            guard choices.count == 1, let owner = choices.first,
                  let members = memberChoices(String(component), owner: owner, path: path, visiting: []) else {
                return nil
            }
            choices = members
        }
        return choices
    }

    private func memberChoices(_ name: String, owner: Int, path: String, visiting: Set<Int>) -> [Int]? {
        guard !visiting.contains(owner) else { return nil }
        let visited = visiting.union([owner])
        let node = nodes[owner]
        if owner >= inventory.nominals.count {
            // Only transparent top-level ancestry aliases are expanded here.
            // Nested/generic ancestry binding requires unsupported semantics.
            guard node.parent == nil, let target = node.bases.first else { return nil }
            guard let choices = lookup(target, path: node.site.path, scope: ""),
                  choices.count == 1, let choice = choices.first else { return nil }
            return memberChoices(name, owner: choice, path: path, visiting: visited)
        }
        let nominal = inventory.nominals[owner]
        guard !nominal.genericParameters.contains(name),
              let own = bindings.ownMembers(name, owner: owner, path: path) else { return nil }
        if !visiting.isEmpty && !nominal.genericParameters.isEmpty { return nil }
        // Records conservatively combine private/fileprivate. A restricted
        // inherited member cannot establish a binding even in the same file.
        if !visiting.isEmpty && own.contains(where: { bindings.restriction($0) != false }) { return nil }
        if !own.isEmpty { return own }
        if !nominal.isClass && nominal.unsupported { return nil }
        return inheritedChoices(name, owner: owner, path: path, visiting: visited)
    }

    private func inheritedChoices(_ name: String, owner: Int, path: String, visiting: Set<Int>) -> [Int]? {
        var result: [Int] = []
        for base in inventory.nominals[owner].bases {
            guard let choices = baseChoices(base, owner: owner), choices.count == 1, let choice = choices.first,
                  let members = memberChoices(name, owner: choice, path: path, visiting: visiting) else { return nil }
            result += members
        }
        return result
    }

    private func baseChoices(_ base: String?, owner: Int) -> [Int]? {
        guard let base else { return [] }
        if let cached = baseBindings[owner]?[base] { return cached.choices }
        let choices = findBaseChoices(base, owner: owner)
        baseBindings[owner, default: [:]][base] = choices.map(BaseBinding.resolved) ?? .indeterminate
        return choices
    }

    private func findBaseChoices(_ base: String, owner: Int) -> [Int]? {
        guard let first = base.split(separator: ".").first.map(String.init) else { return [] }
        if owner >= inventory.nominals.count,
           inventory.aliases[owner - inventory.nominals.count].genericParameters.contains(first) { return [] }
        var context: OwnerContext? = owner < inventory.nominals.count ? .nominal(owner) : nodes[owner].parent
        while let current = context {
            guard case .nominal(let number) = current else { return [] }
            let nominal = inventory.nominals[number]
            // Do not bind a base through a generic parameter or assume absence
            // of inherited names in an enclosing type/extension.
            if nominal.genericParameters.contains(first) { return [] }
            if number != owner && !nominal.bases.isEmpty { return [] }
            context = nominal.parent
        }
        let node = nodes[owner]
        let scope = node.qualified?.split(separator: ".").dropLast().joined(separator: ".") ?? ""
        if let root = lexicalBaseRoot(base, owner: owner) {
            return dottedBaseChoices(base, root: root, path: node.site.path)
        }
        return lookup(base, path: node.site.path, scope: scope)
    }

    private func dottedBaseChoices(_ base: String, root: String, path: String) -> [Int]? {
        guard var choices = exactChoices(root, path: path) else { return nil }
        for component in base.split(separator: ".").dropFirst() {
            guard choices.count == 1, let choice = choices.first, choice < inventory.nominals.count,
                  inventory.nominals[choice].genericParameters.isEmpty else { return [] }
            guard let members = bindings.ownMembers(String(component), owner: choice, path: path) else { return nil }
            choices = members
        }
        return choices
    }

    private func lexicalBaseRoot(_ base: String, owner: Int) -> String? {
        guard let first = base.split(separator: ".").first else { return nil }
        var prefixes = nodes[owner].qualified?.split(separator: ".").dropLast().map(String.init) ?? []
        while true {
            let name = (prefixes + [String(first)]).joined(separator: ".")
            // A raw bucket can contain only foreign members. Continue outward
            // for proved absence, but stop on nil (indeterminate) or candidates.
            if !bindings.indexed(name).isEmpty,
               bindings.exact(name, path: nodes[owner].site.path) != [] { return name }
            if prefixes.isEmpty { return nil }
            prefixes.removeLast()
        }
    }

    private func ancestryPath(_ type: TypeSyntax) -> String? {
        // Rejection-only spelling: never substitute generic arguments or prove ordinary ancestry.
        if let identifier = type.as(IdentifierTypeSyntax.self) { return sourceName(identifier.name) }
        if let member = type.as(MemberTypeSyntax.self), let base = ancestryPath(member.baseType) {
            return base + "." + sourceName(member.name)
        }
        if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
           let element = tuple.elements.first, element.firstName == nil,
           element.secondName == nil, element.ellipsis == nil { return ancestryPath(element.type) }
        return nil
    }

    private func needsEnclosingBinding(_ context: OwnerContext?, visiting: Set<OwnerContext> = []) -> Bool {
        guard let context else { return false }
        guard !visiting.contains(context) else { return true }
        let visited = visiting.union([context])
        switch context {
        case .nominal(let number):
            let nominal = inventory.nominals[number]
            return !nominal.bases.isEmpty || needsEnclosingBinding(nominal.parent, visiting: visited)
        case .extended(let number):
            guard let owner = bindings.extensionTarget(number) else { return true }
            return needsEnclosingBinding(.nominal(owner), visiting: visited)
        case .local: return false
        }
    }

    private func validateContextualAncestry(_ number: Int) throws -> Bool {
        let enclosing = hasExtensionContext(nodes[number].parent) || needsEnclosingBinding(nodes[number].parent)
        for type in nodes[number].baseTypes {
            if let path = ancestryPath(type) { try validateLocalConsumption(path, owner: number) }
            if enclosing {
                try validateEnclosingBinding(type, owner: number)
            } else if let path = ancestryPath(type) {
                // Current-module qualification is not an external SDK spelling. Refuse
                // rather than strip it; a lexical source namespace still binds normally.
                try require(!path.hasPrefix(inventory.variant.matrix.module + ".") ||
                            lexicalBaseRoot(path, owner: number) != nil, "unsupported current-module XCTest ancestry")
            }
        }
        return enclosing
    }

    private func hasExtensionContext(_ context: OwnerContext?) -> Bool {
        switch context {
        case .nominal(let number): return hasExtensionContext(inventory.nominals[number].parent)
        case .extended: return true
        case .none, .local: return false
        }
    }

    private func validateLocalConsumption(_ base: String, owner: Int) throws {
        guard base.contains("."), let first = base.split(separator: ".").first.map(String.init) else { return }
        if owner >= inventory.nominals.count,
           inventory.aliases[owner - inventory.nominals.count].genericParameters.contains(first) { return }
        var context: OwnerContext? = owner < inventory.nominals.count ? .nominal(owner) : nodes[owner].parent
        while let current = context {
            switch current {
            case .nominal(let number):
                let nominal = inventory.nominals[number]
                if nominal.genericParameters.contains(first) { return }
                context = nominal.parent
            case .local:
                // Presence is only grounds for unsupported local consumption, not
                // a winning binding over local shadows. No hit is not proof of absence.
                try require(bindings.indexed(base).isEmpty,
                            "unsupported source-associated local XCTest ancestry: \(nodes[owner].site)")
                return
            case .extended: return
            }
        }
    }

    private func validateEnclosingBinding(_ type: TypeSyntax, owner: Int) throws {
        let node = nodes[owner]
        let alias = owner >= inventory.nominals.count ? inventory.aliases[owner - inventory.nominals.count] : nil
        let parameters = alias?.genericParameters ?? inventory.nominals[owner].genericParameters
        guard let base = ancestryPath(type), let first = base.split(separator: ".").first.map(String.init),
              !parameters.contains(first),
              let roots = scopedChoices(first, path: node.site.path, context: node.parent) else {
            throw AuditFailure("indeterminate enclosing XCTest ancestry: \(node.site)")
        }
        try require(first != inventory.variant.matrix.module || !roots.isEmpty,
                    "unsupported current-module XCTest ancestry")
        if roots.isEmpty && base.contains(".") {
            // Rejection only: contextual base lookup deliberately declines ordinary
            // binding, but an absent first component cannot erase indexed provenance.
            let scope = node.qualified?.split(separator: ".").dropLast().joined(separator: ".") ?? ""
            try require(lookup(base, path: node.site.path, scope: scope) != nil,
                        "indeterminate contextual source-bound XCTest ancestry: \(node.site)")
        }
        try require(SourceInventory.ancestryName(type) != nil || !base.contains("."),
                    "unsupported specialized enclosing XCTest ancestry")
        try require(!base.contains(".") || roots.allSatisfy {
            $0 < inventory.nominals.count && inventory.nominals[$0].genericParameters.isEmpty
        },
                    "unsupported enclosing XCTest namespace alias")
        guard let choices = qualifiedChoices(base, first: roots, path: node.site.path) else {
            throw AuditFailure("indeterminate enclosing XCTest member ancestry: \(node.site)")
        }
        try require(choices.count == 1 || roots.isEmpty && (alias == nil || alias?.value != nil),
                    "ambiguous/unresolved enclosing XCTest ancestry")
        // Rejection only: do not feed these bindings into lineage's ordinary proof.
        for choice in choices {
            try require(lineage(choice) != .xctest, "unsupported inherited enclosing XCTest ancestry")
            try validateAncestryBindings(choice)
        }
    }

    private func validateAncestryBindings(_ number: Int) throws {
        try require(!activeAncestry.contains(number), "cyclic XCTest ancestry binding: \(nodes[number].site)")
        if validatedAncestry.contains(number) { return }
        activeAncestry.insert(number)
        defer { activeAncestry.remove(number) }
        try checkAncestryBindings(number)
        validatedAncestry.insert(number)
    }

    private func checkAncestryBindings(_ number: Int) throws {
        if try validateContextualAncestry(number) { return }
        let erased = number >= inventory.nominals.count &&
            inventory.aliases[number - inventory.nominals.count].value == nil
        for type in nodes[number].baseTypes where erased || SourceInventory.ancestryName(type) == nil {
            let path = ancestryPath(type)
            if let path { _ = try checkedBaseChoices(path, owner: number) }
            guard let path, lexicalBaseRoot(path, owner: number) != nil else {
                try require(!erased, "unsupported erased generic XCTest ancestry: \(nodes[number].site)")
                continue
            }
            try require(SourceInventory.ancestryName(type) != nil || !path.contains("."),
                        "unsupported specialized source-bound XCTest ancestry: \(nodes[number].site)")
            let choices = try checkedBaseChoices(path, owner: number)
            try require(choices.count == 1, "unsupported specialized XCTest ancestry binding: \(nodes[number].site)")
            // Every erased initializer participates, including supported names. This
            // traversal rejects ancestry; it never supplies an ordinary lineage proof.
            for choice in choices {
                try require(lineage(choice) != .xctest, "unsupported erased XCTest ancestry")
                try validateAncestryBindings(choice)
            }
        }
        // A nearer alias/ambiguous/restricted namespace must not silently become
        // an ordinary global member, even for EMPTY classes. Namespace alias
        // expansion and inherited namespace members remain unsupported here.
        for base in nodes[number].bases {
            let choices = try checkedBaseChoices(base, owner: number)
            if let base, lexicalBaseRoot(base, owner: number) != nil {
                try require(choices.count == 1,
                            "unsupported shadowed/indeterminate XCTest ancestry: \(nodes[number].site)")
            }
            for choice in choices { try validateAncestryBindings(choice) }
        }
    }

    private func lineage(_ number: Int) -> Lineage {
        if let cached = lineages[number] { return cached }
        guard activeLineage.insert(number).inserted else {
            // A back edge makes these partial results path-dependent. Never
            // memoize them as completed unknown (or ordinary) ancestry.
            cyclicLineage.formUnion(activeLineage)
            return .unknown
        }
        defer { activeLineage.remove(number) }
        let result = computeLineage(number)
        if cyclicLineage.remove(number) == nil { lineages[number] = result }
        return result
    }

    private func checkedBaseChoices(_ base: String?, owner: Int) throws -> [Int] {
        // An indexed member can have unresolved extension provenance even when
        // its first component has no source nominal. Never cache that as absence.
        guard let choices = baseChoices(base, owner: owner) else {
            throw AuditFailure("indeterminate source-bound XCTest ancestry: \(nodes[owner].site)")
        }
        return choices
    }

    private func unshadowedXCTest(_ base: String?, owner: Int) -> Bool {
        guard let base, base == "XCTestCase" || base == "XCTest.XCTestCase",
              lexicalBaseRoot(base, owner: owner) == nil else { return false }
        let node = nodes[owner]
        if needsEnclosingBinding(node.parent) {
            let first = base.split(separator: ".").first.map(String.init) ?? ""
            // An inherited source binding blocks SDK fallback, but cannot prove
            // ordinary lineage through this rejection-only contextual lookup.
            return scopedChoices(first, path: node.site.path, context: node.parent)?.isEmpty == true
        }
        return true
    }

    private func computeLineage(_ number: Int) -> Lineage {
        let node = nodes[number]
        let parents = node.bases.map { base -> Lineage in
            guard let choices = baseChoices(base, owner: number) else { return .unknown }
            if choices.count == 1, let choice = choices.first { return lineage(choice) }
            return unshadowedXCTest(base, owner: number) ? .xctest : .unknown
        }
        if parents.contains(.xctest) { return .xctest }
        if parents.contains(.unknown) { return .unknown }
        if bindings.restriction(number) == nil { return .unknown }
        // Aliases/types declared in local or extension scopes are not semantically
        // resolved by this guard; they cannot establish safe ancestry for tests.
        if case .extended = node.parent { return .unknown }
        if case .local = node.parent { return .unknown }
        return .ordinary
    }
}
