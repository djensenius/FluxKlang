// One post-inventory identity/access index shared by root, ancestry, and return
// consumers. This resolves supported source extension targets, not Swift types.
final class SourceExtensionOwnership {
    private struct Entry {
        let name: String?
        let path: String
        let parent: OwnerContext?
        let restricted: Bool
    }

    private struct MemberKey: Hashable {
        let owner: Int
        let name: String
        let path: String
    }

    private struct TransitiveKey: Hashable {
        let member: MemberKey
        let inherited: Bool
    }

    private let inventory: SourceInventory
    private let entries: [Entry]
    private var index: [String: [Int]] = [:]
    private var targets: [Int: Int] = [:]
    private var activeTargets: Set<Int> = []
    private var restrictions: [Int: Bool] = [:]
    private var activeRestrictions: Set<Int> = []
    private var members: [MemberKey: [Int]] = [:]
    private var transitive: [TransitiveKey: [Int]] = [:]

    init(_ inventory: SourceInventory) {
        self.inventory = inventory
        entries = inventory.nominals.map {
            Entry(name: $0.qualified, path: $0.site.path, parent: $0.parent, restricted: $0.restricted)
        } + inventory.aliases.map {
            Entry(name: $0.qualified, path: $0.site.path, parent: $0.parent, restricted: $0.restricted)
        }
        for (number, entry) in entries.enumerated() {
            if let name = entry.name { index[name, default: []].append(number) }
        }
    }

    // Raw presence is useful only to block terminal/module fallback, not to
    // establish a binding. IDs retain the nominal-then-alias inventory ordering.
    func indexed(_ name: String) -> [Int] {
        index[name] ?? []
    }

    func extensionTarget(_ number: Int) -> Int? {
        if let target = targets[number] { return target }
        guard activeTargets.insert(number).inserted else { return nil }
        defer { activeTargets.remove(number) }
        let extended = inventory.extensions[number]
        guard !extended.unsupported, let name = extended.qualified,
              let choices = exact(name, path: extended.site.path),
              choices.count == 1, let target = choices.first, target < inventory.nominals.count else { return nil }
        targets[number] = target
        return target
    }

    // nil is indeterminate, including unresolved extension provenance. Restriction
    // belongs to the actual target/owner chain, not its printed qualified name.
    func restriction(_ number: Int) -> Bool? {
        if let cached = restrictions[number] { return cached }
        guard activeRestrictions.insert(number).inserted else { return nil }
        defer { activeRestrictions.remove(number) }
        let entry = entries[number]
        let inherited: Bool
        switch entry.parent {
        case .none: inherited = false
        case .nominal(let owner):
            guard let value = restriction(owner) else { return nil }
            inherited = value
        case .extended(let extended):
            guard let owner = extensionTarget(extended), let value = restriction(owner) else { return nil }
            inherited = value || inventory.extensions[extended].restricted
        case .local: return nil
        }
        let result = entry.restricted || inherited
        restrictions[number] = result
        return result
    }

    func exact(_ name: String, path: String) -> [Int]? {
        let components = name.split(separator: ".").map(String.init)
        guard let first = components.first else { return nil }
        let raw = indexed(first)
        // Private declarations in two files are distinct roots. An inaccessible
        // spelling alone, however, cannot prove absence for SDK/builtin fallback.
        let visible = raw.filter { !entries[$0].restricted || entries[$0].path == path }
        if !raw.isEmpty && visible.isEmpty { return nil }
        var choices = visible
        for component in components.dropFirst() {
            guard choices.count == 1, let owner = choices.first, owner < inventory.nominals.count,
                  inventory.nominals[owner].genericParameters.isEmpty,
                  let next = ownMembers(component, owner: owner, path: path) else { return nil }
            choices = next
        }
        return choices
    }

    func lexical(_ name: String?, path: String, scope: String) -> [Int]? {
        guard let name else { return nil }
        var prefixes = scope.split(separator: ".").map(String.init)
        var spellings: Set<String> = [name]
        while !prefixes.isEmpty {
            spellings.insert(prefixes.joined(separator: ".") + "." + name)
            prefixes.removeLast()
        }
        var result: [Int] = []
        for spelling in spellings.sorted() {
            // Missing lexical prefixes do not mask a supported global binding.
            if indexed(spelling).isEmpty { continue }
            guard let choices = exact(spelling, path: path) else { return nil }
            result += choices
        }
        return result.sorted()
    }

    func ownMembers(_ name: String, owner: Int, path: String) -> [Int]? {
        let key = MemberKey(owner: owner, name: name, path: path)
        if let cached = members[key] { return cached }
        guard owner < inventory.nominals.count, let qualified = entries[owner].name,
              let restricted = restriction(owner), !restricted || entries[owner].path == path else { return nil }
        var result: [Int] = []
        for candidate in indexed(qualified + "." + name) {
            guard let actual = declaringOwner(candidate) else { return nil }
            // Only proven foreign identity permits inherited lookup to continue.
            if actual != owner { continue }
            guard let restricted = restriction(candidate),
                  !restricted || entries[candidate].path == path else { return nil }
            result.append(candidate)
        }
        // Only completed determinate results are cached; active-cycle/unknown
        // results cannot become cached absence or ordinary/non-Void evidence.
        members[key] = result
        return result
    }

    func declarationChoices(_ number: Int) -> [Int]? {
        let entry = entries[number]
        guard let name = entry.name else { return nil }
        if entry.parent == nil { return exact(name, path: entry.path) }
        guard let owner = declaringOwner(number), let component = name.split(separator: ".").last else { return nil }
        return ownMembers(String(component), owner: owner, path: entry.path)
    }

    // Distinct from direct membership. The caller checks its visited owners
    // before entry; only fully returned arrays (including empty) are published.
    func transitiveMembers(
        _ name: String, owner: Int, path: String, inherited: Bool, compute: () -> [Int]?
    ) -> [Int]? {
        let key = TransitiveKey(member: MemberKey(owner: owner, name: name, path: path), inherited: inherited)
        if let cached = transitive[key] { return cached }
        guard let result = compute() else { return nil }
        transitive[key] = result
        return result
    }

    private func declaringOwner(_ number: Int) -> Int? {
        switch entries[number].parent {
        case .nominal(let owner):
            // The lexical parent is an identity, but its extension provenance
            // must also be determinate before treating this member as foreign.
            guard restriction(owner) != nil else { return nil }
            return owner
        case .extended(let extended): return extensionTarget(extended)
        case .none, .local: return nil
        }
    }
}
