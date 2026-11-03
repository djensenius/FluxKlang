import SwiftSyntax

// This is a rejection guard, not XCTest discovery or general Swift semantic
// resolution. Unknown/ambiguous ancestry is never evidence that a test-shaped
// inherited class is a helper. Plain helpers without discovery-shaped members
// remain valid unless their supported ancestry actually reaches XCTestCase.
struct XCTestDiscoveryGuard {
    enum Lineage { case ordinary, xctest, unknown }
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

    init(_ inventory: SourceInventory) {
        self.inventory = inventory
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
            let choices = lookup(extended.qualified, path: extended.site.path, scope: "")
            try require(choices.count == 1, "unsupported XCTest-shaped extension ownership: \(extended.site)")
            guard let owner = choices.first else { throw AuditFailure("unresolved XCTest-shaped extension") }
            try require(lineage(owner, visiting: []) == .ordinary,
                        "unsupported XCTest-shaped extension ancestry: \(extended.site)")
            if owner < inventory.nominals.count { shaped.insert(.nominal(owner)) }
        }
        for (number, nominal) in inventory.nominals.enumerated() where nominal.isClass {
            try validateAncestryBindings(number, visiting: [])
            let ancestry = lineage(number, visiting: [])
            try require(ancestry != .xctest, "unsupported XCTest discovery-bearing class: \(nominal.site)")
            if !nominal.bases.isEmpty && shaped.contains(.nominal(number)) {
                try require(ancestry == .ordinary,
                            "unresolved/ambiguous XCTest-shaped class ancestry: \(nominal.site)")
            }
        }
    }

    private func lookup(_ name: String?, path: String, scope: String) -> [Int] {
        guard let name else { return [] }
        var prefixes = scope.split(separator: ".").map(String.init)
        var spellings: Set<String> = [name]
        while !prefixes.isEmpty {
            spellings.insert(prefixes.joined(separator: ".") + "." + name)
            prefixes.removeLast()
        }
        return nodes.indices.filter {
            guard let qualified = nodes[$0].qualified else { return false }
            return spellings.contains(qualified) && (!nodes[$0].restricted || nodes[$0].site.path == path)
        }
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
            let name = inventory.extensions[index].qualified ?? ""
            let owners = lookup(name, path: site.path, scope: "").filter { $0 < inventory.nominals.count }
            let inherited = owners.reduce(parameters) {
                $0.union(returnScope(site: site, context: .nominal($1)).parameters)
            }
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
            let extended = inventory.extensions[number]
            guard !extended.unsupported else { return nil }
            let owners = lookup(extended.qualified, path: path, scope: "")
            guard owners.count == 1, let owner = owners.first,
                  let members = memberChoices(name, owner: owner, path: path, visiting: []) else { return nil }
            if !members.isEmpty { return members }
            return exactChoices(name, path: path)
        case .none: return exactChoices(name, path: path)
        case .local: return nil
        }
    }

    private func exactChoices(_ name: String, path: String) -> [Int]? {
        let matches = nodes.indices.filter { nodes[$0].qualified == name }
        for match in matches {
            if nodes[match].restricted && nodes[match].site.path != path { return nil }
            if case .extended(let number) = nodes[match].parent,
               inventory.extensions[number].unsupported { return nil }
        }
        return matches
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
            let choices = lookup(target, path: node.site.path, scope: "")
            guard choices.count == 1, let choice = choices.first else { return nil }
            return memberChoices(name, owner: choice, path: path, visiting: visited)
        }
        let nominal = inventory.nominals[owner]
        guard !nominal.genericParameters.contains(name), let qualified = nominal.qualified,
              let own = exactChoices(qualified + "." + name, path: path) else { return nil }
        if !visiting.isEmpty && !nominal.genericParameters.isEmpty { return nil }
        // Records conservatively combine private/fileprivate. A restricted
        // inherited member cannot establish a binding even in the same file.
        if !visiting.isEmpty && own.contains(where: { nodes[$0].restricted }) { return nil }
        if !own.isEmpty { return own }
        if !nominal.isClass && nominal.unsupported { return nil }
        return inheritedChoices(name, owner: owner, path: path, visiting: visited)
    }

    private func inheritedChoices(_ name: String, owner: Int, path: String, visiting: Set<Int>) -> [Int]? {
        var result: [Int] = []
        for base in inventory.nominals[owner].bases {
            let choices = baseChoices(base, owner: owner)
            guard choices.count == 1, let choice = choices.first,
                  let members = memberChoices(name, owner: choice, path: path, visiting: visiting) else { return nil }
            result += members
        }
        return result
    }

    private func baseChoices(_ base: String?, owner: Int) -> [Int] {
        guard let first = base?.split(separator: ".").first.map(String.init) else { return [] }
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
        if let base, let root = lexicalBaseRoot(base, owner: owner) {
            var choices = exactChoices(root, path: node.site.path) ?? []
            for component in base.split(separator: ".").dropFirst() {
                guard choices.count == 1, let choice = choices.first, choice < inventory.nominals.count,
                      inventory.nominals[choice].genericParameters.isEmpty,
                      let name = nodes[choice].qualified else { return [] }
                choices = exactChoices(name + "." + component, path: node.site.path) ?? []
            }
            return choices
        }
        return lookup(base, path: node.site.path, scope: scope)
    }

    private func lexicalBaseRoot(_ base: String, owner: Int) -> String? {
        guard let first = base.split(separator: ".").first else { return nil }
        var prefixes = nodes[owner].qualified?.split(separator: ".").dropLast().map(String.init) ?? []
        while true {
            let name = (prefixes + [String(first)]).joined(separator: ".")
            if nodes.contains(where: { $0.qualified == name }) { return name }
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
            let extended = inventory.extensions[number]
            let owners = lookup(extended.qualified, path: extended.site.path, scope: "")
            guard owners.count == 1, let owner = owners.first, owner < inventory.nominals.count else { return true }
            return needsEnclosingBinding(.nominal(owner), visiting: visited)
        case .local: return false
        }
    }

    private func validateContextualAncestry(_ number: Int, visiting: Set<Int>) throws -> Bool {
        let enclosing = needsEnclosingBinding(nodes[number].parent)
        for type in nodes[number].baseTypes {
            if enclosing {
                try validateEnclosingBinding(type, owner: number, visiting: visiting)
            } else if let path = ancestryPath(type) {
                // Current-module qualification is not an external SDK spelling. Refuse
                // rather than strip it; a lexical source namespace still binds normally.
                try require(!path.hasPrefix(inventory.variant.matrix.module + ".") ||
                            lexicalBaseRoot(path, owner: number) != nil, "unsupported current-module XCTest ancestry")
            }
        }
        return enclosing
    }

    private func validateEnclosingBinding(_ type: TypeSyntax, owner: Int, visiting: Set<Int>) throws {
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
            try require(lineage(choice, visiting: []) != .xctest, "unsupported inherited enclosing XCTest ancestry")
            try validateAncestryBindings(choice, visiting: visiting.union([owner]))
        }
    }

    private func validateAncestryBindings(_ number: Int, visiting: Set<Int>) throws {
        try require(!visiting.contains(number), "cyclic XCTest ancestry binding: \(nodes[number].site)")
        if try validateContextualAncestry(number, visiting: visiting) { return }
        let erased = number >= inventory.nominals.count &&
            inventory.aliases[number - inventory.nominals.count].value == nil
        for type in nodes[number].baseTypes where erased || SourceInventory.ancestryName(type) == nil {
            guard let path = ancestryPath(type), lexicalBaseRoot(path, owner: number) != nil else {
                try require(!erased, "unsupported erased generic XCTest ancestry: \(nodes[number].site)")
                continue
            }
            try require(SourceInventory.ancestryName(type) != nil || !path.contains("."),
                        "unsupported specialized source-bound XCTest ancestry: \(nodes[number].site)")
            let choices = baseChoices(path, owner: number)
            try require(choices.count == 1, "unsupported specialized XCTest ancestry binding: \(nodes[number].site)")
            // Every erased initializer participates, including supported names. This
            // traversal rejects ancestry; it never supplies an ordinary lineage proof.
            for choice in choices {
                try require(lineage(choice, visiting: []) != .xctest, "unsupported erased XCTest ancestry")
                try validateAncestryBindings(choice, visiting: visiting.union([number]))
            }
        }
        // A nearer alias/ambiguous/restricted namespace must not silently become
        // an ordinary global member, even for EMPTY classes. Namespace alias
        // expansion and inherited namespace members remain unsupported here.
        for base in nodes[number].bases {
            let choices = baseChoices(base, owner: number)
            if let base, lexicalBaseRoot(base, owner: number) != nil {
                try require(choices.count == 1,
                            "unsupported shadowed/indeterminate XCTest ancestry: \(nodes[number].site)")
            }
            for choice in choices { try validateAncestryBindings(choice, visiting: visiting.union([number])) }
        }
    }

    private func lineage(_ number: Int, visiting: Set<Int>) -> Lineage {
        guard !visiting.contains(number) else { return .unknown }
        let node = nodes[number]
        let visited = visiting.union([number])
        let parents = node.bases.map { base -> Lineage in
            if base == "XCTestCase" || base == "XCTest.XCTestCase" { return .xctest }
            let choices = baseChoices(base, owner: number)
            guard choices.count == 1, let choice = choices.first else { return .unknown }
            return lineage(choice, visiting: visited)
        }
        if parents.contains(.xctest) { return .xctest }
        if parents.contains(.unknown) { return .unknown }
        // Aliases/types declared in local or extension scopes are not semantically
        // resolved by this guard; they cannot establish safe ancestry for tests.
        if case .extended = node.parent { return .unknown }
        if case .local = node.parent { return .unknown }
        return .ordinary
    }
}
