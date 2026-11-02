import Foundation
import SwiftSyntax

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

struct SourceOwnership {
    let inventory: SourceInventory
    private var index: [String: [Int]] = [:]

    init(_ inventory: SourceInventory) {
        self.inventory = inventory
        for (number, nominal) in inventory.nominals.enumerated() {
            if let name = nominal.qualified { index[name, default: []].append(number) }
        }
    }

    private func candidates(_ name: String, path: String) -> [Int] {
        (index[name] ?? []).filter {
            !inventory.nominals[$0].restricted || inventory.nominals[$0].site.path == path
        }
    }

    private func extendedOwner(_ number: Int) throws -> Int {
        let extended = inventory.extensions[number]
        try require(!extended.unsupported, "unsupported constrained/inherited/local test extension: \(extended.site)")
        guard let name = extended.qualified else { throw AuditFailure("unsupported specialized extended test type") }
        var prefix: [String] = []
        for component in name.split(separator: ".").map(String.init) {
            prefix.append(component)
            try require(candidates(prefix.joined(separator: "."), path: extended.site.path).count == 1,
                        "unresolved/ambiguous dotted test extension: \(extended.site.path): \(name)")
        }
        let choices = candidates(name, path: extended.site.path)
        try require(choices.count == 1, "unresolved/ambiguous test extension: \(extended.site.path): \(name)")
        guard let choice = choices.first else { throw AuditFailure("missing extension owner") }
        return choice
    }

    private func root(_ context: OwnerContext, visiting: Set<OwnerContext> = []) throws -> Int {
        try require(!visiting.contains(context), "cyclic test ownership")
        let visited = visiting.union([context])
        switch context {
        case .local: throw AuditFailure("unsupported local test/suite context")
        case .extended(let number):
            let owner = try root(.nominal(extendedOwner(number)), visiting: visited)
            let extended = inventory.extensions[number]
            let outerName = extended.qualified?.split(separator: ".").first.map(String.init) ?? ""
            try require(candidates(outerName, path: extended.site.path) == [owner],
                        "ambiguous private dotted-extension root: \(extended.site.path)")
            return owner
        case .nominal(let number):
            let nominal = inventory.nominals[number]
            try require(!nominal.unsupported, "unsupported generic/inherited/protocol test owner: \(nominal.site)")
            guard let name = nominal.qualified else { throw AuditFailure("unresolved nominal test owner") }
            try require(candidates(name, path: nominal.site.path).count == 1,
                        "overlapping/ambiguous nominal owner: \(nominal.site.path): \(name)")
            if let parent = nominal.parent { return try root(parent, visiting: visited) }
            return number
        }
    }

    func analyze() throws -> (rows: [InventoryRow], diagnostics: [AuditDiagnostic]) {
        try XCTestDiscoveryGuard(inventory).validate()
        var rootTests: [Int: [SourceSite]] = [:]
        var freeTests: [FunctionRecord] = []
        var annotations: [Int: [String]] = [:]
        var unsupported: [Int: [String]] = [:]
        var diagnostics = inventory.misplaced.map {
            diagnostic("annotation", "misplaced Testing/audit annotation", site: $0)
        }
        for (number, nominal) in inventory.nominals.enumerated() {
            let macros = nominal.attributes.filter { SourceAttributes.macro($0) != nil }
            if !macros.isEmpty {
                let owner = try root(.nominal(number))
                rootTests[owner, default: []] += []
                let review = reviewAttributes(nominal.attributes, expected: "Suite", canonical: number == owner)
                annotations[owner, default: []] += review.problems
                unsupported[owner, default: []] += review.unsupported
            }
        }
        for (number, extended) in inventory.extensions.enumerated()
        where extended.attributes.contains(where: { SourceAttributes.macro($0) != nil }) {
            let owner = try root(.extended(number))
            rootTests[owner, default: []] += []
            annotations[owner, default: []].append("Testing annotation on extension: \(extended.site.path)")
            let review = reviewAttributes(extended.attributes, expected: "Suite", canonical: false)
            annotations[owner, default: []] += review.problems
            unsupported[owner, default: []] += review.unsupported
        }
        for function in inventory.functions {
            try require(!function.unsupported, "unsupported generic test function: \(function.site)")
            if let parent = function.parent {
                let owner = try root(parent)
                rootTests[owner, default: []].append(function.site)
                let review = reviewAttributes(function.attributes, expected: "Test", canonical: false)
                annotations[owner, default: []] += review.problems
                unsupported[owner, default: []] += review.unsupported
            } else {
                freeTests.append(function)
            }
        }
        var rows: [InventoryRow] = []
        for number in rootTests.keys.sorted() {
            let nominal = inventory.nominals[number]
            let review = reviewAttributes(nominal.attributes, expected: "Suite", canonical: true)
            let problems = Set((annotations[number] ?? []) + review.problems).sorted()
            let models = Set((unsupported[number] ?? []) + review.unsupported).sorted()
            let row = makeRow(site: nominal.site, kind: "root", name: nominal.qualified ?? nominal.site.name,
                              tests: rootTests[number] ?? [], problems: problems)
            rows.append(row)
            diagnostics += rowDiagnostics(row, unsupported: models)
        }
        for function in freeTests {
            let review = reviewAttributes(function.attributes, expected: "Test", canonical: true)
            let row = makeRow(site: function.site, kind: "freeTest", name: function.site.name,
                              tests: [function.site], problems: review.problems)
            rows.append(row)
            diagnostics += rowDiagnostics(row, unsupported: review.unsupported)
        }
        let registrations = rows.map(\.registration)
        try require(Set(registrations).count == registrations.count, "duplicate source declaration identity")
        return (rows.sorted { $0.registration.sortKey < $1.registration.sortKey }, diagnostics)
    }

    private func reviewAttributes(
        _ attributes: [AttributeSyntax], expected: String, canonical: Bool
    ) -> AnnotationReview {
        var result = AnnotationReview()
        let macros = attributes.compactMap(SourceAttributes.macro)
        if macros.count != 1 || macros.first != expected {
            result.problems.append("requires a single @\(expected), without conflicting Testing macros")
        }
        for attribute in attributes { result.inspect(attribute) }
        if canonical && result.canonicalCount != 1 {
            result.problems.append("requires exactly one bare unlabeled .productionAccessAudit on owning @\(expected)")
        }
        if !canonical && result.canonicalCount != 0 {
            result.problems.append("misplaced audit on nested suite/member test")
        }
        return result
    }

    private func makeRow(
        site: SourceSite, kind: String, name: String, tests: [SourceSite], problems: [String]
    ) -> InventoryRow {
        let matrix = inventory.variant.matrix
        let registration = Registration(
            target: matrix.target, module: matrix.module, path: site.path, kind: kind, name: name,
            configuration: matrix.configuration, guardExpression: inventory.variant.guardExpression,
            requirement: "canonicalProductionAccessAudit")
        return InventoryRow(registration: registration, line: site.line, annotationSatisfied: problems.isEmpty,
                            annotationProblems: problems.sorted(), tests: tests.sorted {
            [$0.path, $0.name, String($0.line)].joined() < [$1.path, $1.name, String($1.line)].joined()
        })
    }

    private func rowDiagnostics(_ row: InventoryRow, unsupported: [String]) -> [AuditDiagnostic] {
        row.annotationProblems.map {
            AuditDiagnostic(category: "annotation", message: $0, registration: row.registration, site: nil)
        } + unsupported.map {
            AuditDiagnostic(category: "model", message: $0, registration: row.registration, site: nil)
        }
    }

    private func diagnostic(_ category: String, _ message: String, site: SourceSite) -> AuditDiagnostic {
        AuditDiagnostic(category: category, message: message, registration: nil, site: site)
    }
}

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
    }

    let inventory: SourceInventory
    let nodes: [Node]

    init(_ inventory: SourceInventory) {
        self.inventory = inventory
        nodes = inventory.nominals.map {
            Node(site: $0.site, qualified: $0.qualified, restricted: $0.restricted,
                 parent: $0.parent, bases: $0.isClass ? $0.bases : [])
        } + inventory.aliases.map {
            Node(site: $0.site, qualified: $0.qualified, restricted: $0.restricted,
                 parent: $0.parent, bases: [$0.target])
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
        return lookup(base, path: node.site.path, scope: scope)
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
