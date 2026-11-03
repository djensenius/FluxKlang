import Foundation
import SwiftSyntax

struct SourceOwnership {
    let inventory: SourceInventory
    private let bindings: SourceExtensionOwnership

    init(_ inventory: SourceInventory) {
        self.inventory = inventory
        bindings = SourceExtensionOwnership(inventory)
    }

    private func extendedOwner(_ number: Int) throws -> Int {
        let extended = inventory.extensions[number]
        try require(!extended.unsupported, "unsupported constrained/inherited/local test extension: \(extended.site)")
        guard let choice = bindings.extensionTarget(number) else {
            throw AuditFailure("unresolved/ambiguous/private test extension: \(extended.site)")
        }
        return choice
    }

    private func root(_ context: OwnerContext, visiting: Set<OwnerContext> = []) throws -> Int {
        try require(!visiting.contains(context), "cyclic test ownership")
        let visited = visiting.union([context])
        switch context {
        case .local: throw AuditFailure("unsupported local test/suite context")
        case .extended(let number):
            return try root(.nominal(extendedOwner(number)), visiting: visited)
        case .nominal(let number):
            let nominal = inventory.nominals[number]
            try require(!nominal.unsupported, "unsupported generic/inherited/protocol test owner: \(nominal.site)")
            guard let name = nominal.qualified else { throw AuditFailure("unresolved nominal test owner") }
            try require(bindings.declarationChoices(number) == [number],
                        "overlapping/ambiguous nominal owner: \(nominal.site.path): \(name)")
            if let parent = nominal.parent { return try root(parent, visiting: visited) }
            return number
        }
    }

    func analyze() throws -> (rows: [InventoryRow], diagnostics: [AuditDiagnostic]) {
        try XCTestDiscoveryGuard(inventory, bindings: bindings).validate()
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

    // V2 performs this role-neutral structural pass for every target/variant
    // before either canonical or qualification obligations are selected.
    func validateDiscovery() throws {
        try XCTestDiscoveryGuard(inventory, bindings: bindings).validate()
        for (number, nominal) in inventory.nominals.enumerated()
        where nominal.attributes.contains(where: { SourceAttributes.macro($0) != nil }) {
            _ = try root(.nominal(number))
        }
        for (number, extended) in inventory.extensions.enumerated()
        where extended.attributes.contains(where: { SourceAttributes.macro($0) != nil }) {
            _ = try root(.extended(number))
        }
        var freeIdentities = Set<String>()
        for function in inventory.functions {
            try require(!function.unsupported, "unsupported generic test function: \(function.site)")
            if let parent = function.parent {
                _ = try root(parent)
            } else {
                let identity = function.site.path + "\u{1F}" + function.site.name
                try require(freeIdentities.insert(identity).inserted, "duplicate source declaration identity")
            }
        }
        let attributes = inventory.nominals.flatMap(\.attributes) + inventory.extensions.flatMap(\.attributes) +
            inventory.functions.flatMap(\.attributes)
        for attribute in attributes {
            var review = AnnotationReview()
            review.inspect(attribute)
            try require(review.unsupported.isEmpty, review.unsupported.joined(separator: "; "))
        }
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
