import AppIntents
import CoreSpotlight
import Foundation

let fluxKlangAppEntityIndexName = "FluxKlang.AppEntities"

struct EquipmentEntity: AppEntity, IndexedEntity, Hashable {
    let id: UUID
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Equipment"
    static let defaultQuery = EquipmentEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "Studio gear")
    }

    var attributeSet: CSSearchableItemAttributeSet { defaultAttributeSet }
}

struct EffectEntity: AppEntity, IndexedEntity, Hashable {
    let id: UUID
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Effect"
    static let defaultQuery = EffectEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "Active environment effect")
    }

    var attributeSet: CSSearchableItemAttributeSet { defaultAttributeSet }
}

struct EnvironmentEntity: AppEntity, IndexedEntity, Hashable {
    let id: UUID
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Environment"
    static let defaultQuery = EnvironmentEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "Studio environment")
    }

    var attributeSet: CSSearchableItemAttributeSet { defaultAttributeSet }
}

struct DestinationEntity: AppEntity, IndexedEntity, Hashable {
    let id: UUID
    let name: String
    let destination: StudioEndpointDestination

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static let defaultQuery = DestinationEntityQuery()

    static let finalMix = DestinationEntity(
        id: UUID(uuidString: "7BE88A20-4442-5BB2-B10C-F121A81DD76B")!,
        name: "Final Mix",
        destination: .finalMix
    )
    static let space = DestinationEntity(
        id: UUID(uuidString: "FAAE2333-F097-5509-843B-382C1F9CDA0D")!,
        name: "Space",
        destination: .space
    )
    static let custom = DestinationEntity(
        id: UUID(uuidString: "5EA7E64A-D999-5D37-AC72-7685EB3CA5F7")!,
        name: "Custom Stem",
        destination: .custom
    )
    static let all = [finalMix, space, custom]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    var attributeSet: CSSearchableItemAttributeSet { defaultAttributeSet }
}

struct EquipmentEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [EquipmentEntity] {
        await AppModel.shared.equipment.load()
        return Self.entities(for: identifiers, in: AppModel.shared.equipment.items)
    }

    @MainActor
    func suggestedEntities() async throws -> [EquipmentEntity] {
        await AppModel.shared.equipment.load()
        return AppModel.shared.equipment.items.map(EquipmentEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [EquipmentEntity] {
        await AppModel.shared.equipment.load()
        return Self.entities(matching: string, in: AppModel.shared.equipment.items)
    }

    static func entities(for identifiers: [UUID], in equipment: [Equipment]) -> [EquipmentEntity] {
        let byID = Dictionary(equipment.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0].map(EquipmentEntity.init) }
    }

    static func entities(matching string: String, in equipment: [Equipment]) -> [EquipmentEntity] {
        SiriEntityMatcher.matches(string, values: equipment, name: \.name).map(EquipmentEntity.init)
    }
}

struct EffectEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [EffectEntity] {
        await AppModel.shared.environments.load()
        return Self.entities(for: identifiers, in: AppModel.shared.environments.activeEffects)
    }

    @MainActor
    func suggestedEntities() async throws -> [EffectEntity] {
        await AppModel.shared.environments.load()
        return AppModel.shared.environments.activeEffects.map(EffectEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [EffectEntity] {
        await AppModel.shared.environments.load()
        return Self.entities(matching: string, in: AppModel.shared.environments.activeEffects)
    }

    static func entities(for identifiers: [UUID], in effects: [Effect]) -> [EffectEntity] {
        let byID = Dictionary(effects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0].map(EffectEntity.init) }
    }

    static func entities(matching string: String, in effects: [Effect]) -> [EffectEntity] {
        SiriEntityMatcher.matches(string, values: effects, name: \.name).map(EffectEntity.init)
    }
}

struct EnvironmentEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [EnvironmentEntity] {
        await AppModel.shared.environments.load()
        return Self.entities(for: identifiers, in: AppModel.shared.environments.environments)
    }

    @MainActor
    func suggestedEntities() async throws -> [EnvironmentEntity] {
        await AppModel.shared.environments.load()
        return AppModel.shared.environments.environments.map(EnvironmentEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [EnvironmentEntity] {
        await AppModel.shared.environments.load()
        return Self.entities(matching: string, in: AppModel.shared.environments.environments)
    }

    static func entities(for identifiers: [UUID], in environments: [RoutingEnvironment]) -> [EnvironmentEntity] {
        let byID = Dictionary(environments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0].map(EnvironmentEntity.init) }
    }

    static func entities(matching string: String, in environments: [RoutingEnvironment]) -> [EnvironmentEntity] {
        SiriEntityMatcher.matches(string, values: environments, name: \.name).map(EnvironmentEntity.init)
    }
}

struct DestinationEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [DestinationEntity] {
        Self.entities(for: identifiers)
    }

    func suggestedEntities() async throws -> [DestinationEntity] {
        DestinationEntity.all
    }

    func entities(matching string: String) async throws -> [DestinationEntity] {
        Self.entities(matching: string)
    }

    static func entities(for identifiers: [UUID]) -> [DestinationEntity] {
        let byID = Dictionary(DestinationEntity.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    static func entities(matching string: String) -> [DestinationEntity] {
        SiriEntityMatcher.matches(string, values: DestinationEntity.all, name: \.name)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension EquipmentEntity: SyncableEntity {}

@available(iOS 27.0, macOS 27.0, *)
extension EffectEntity: SyncableEntity {}

@available(iOS 27.0, macOS 27.0, *)
extension EnvironmentEntity: SyncableEntity {}

@available(iOS 27.0, macOS 27.0, *)
extension DestinationEntity: SyncableEntity {}

@available(iOS 27.0, macOS 27.0, *)
extension EquipmentEntityQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [UUID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        try await fluxKlangSpotlightIndex(
            protectionClass: indexDescription.protectionClass
        ).indexAppEntities(try await entities(for: identifiers))
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await fluxKlangSpotlightIndex(
            protectionClass: indexDescription.protectionClass
        ).indexAppEntities(try await suggestedEntities())
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension EffectEntityQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [UUID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        try await fluxKlangSpotlightIndex(
            protectionClass: indexDescription.protectionClass
        ).indexAppEntities(try await entities(for: identifiers))
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await fluxKlangSpotlightIndex(
            protectionClass: indexDescription.protectionClass
        ).indexAppEntities(try await suggestedEntities())
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension EnvironmentEntityQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [UUID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        try await fluxKlangSpotlightIndex(
            protectionClass: indexDescription.protectionClass
        ).indexAppEntities(try await entities(for: identifiers))
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await fluxKlangSpotlightIndex(
            protectionClass: indexDescription.protectionClass
        ).indexAppEntities(try await suggestedEntities())
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension DestinationEntityQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [UUID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        try await fluxKlangSpotlightIndex(
            protectionClass: indexDescription.protectionClass
        ).indexAppEntities(try await entities(for: identifiers))
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await fluxKlangSpotlightIndex(
            protectionClass: indexDescription.protectionClass
        ).indexAppEntities(try await suggestedEntities())
    }
}

func fluxKlangSpotlightIndex(protectionClass: FileProtectionType?) -> CSSearchableIndex {
    CSSearchableIndex(
        name: fluxKlangAppEntityIndexName,
        protectionClass: protectionClass
    )
}

enum SiriEntityMatcher {
    private struct Ranked<Value> {
        let score: Int
        let index: Int
        let value: Value
    }

    static func matches<Value>(
        _ spoken: String,
        values: [Value],
        name: KeyPath<Value, String>
    ) -> [Value] {
        let query = normalize(spoken)
        guard !query.isEmpty else { return values }
        return values.enumerated()
            .compactMap { index, value -> Ranked<Value>? in
                guard let score = score(query: query, candidate: normalize(value[keyPath: name])) else {
                    return nil
                }
                return Ranked(score: score, index: index, value: value)
            }
            .sorted { ($0.score, $0.index) < ($1.score, $1.index) }
            .map(\.value)
    }

    private static func score(query: String, candidate: String) -> Int? {
        if candidate == query { return 0 }
        if candidate.hasPrefix(query) { return 10 + candidate.count - query.count }
        if candidate.contains(query) { return 30 + candidate.count - query.count }
        let compactQuery = query.replacingOccurrences(of: " ", with: "")
        let compactCandidate = candidate.replacingOccurrences(of: " ", with: "")
        if compactCandidate.contains(compactQuery) {
            return 40 + compactCandidate.count - compactQuery.count
        }
        let queryWords = query.split(separator: " ")
        let candidateWords = candidate.split(separator: " ")
        if queryWords.allSatisfy({ word in candidateWords.contains { $0.hasPrefix(word) } }) {
            return 50 + candidateWords.count - queryWords.count
        }
        let distance = editDistance(query, candidate)
        let allowance = max(1, min(3, query.count / 4))
        return distance <= allowance ? 100 + distance : nil
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }
}

extension EquipmentEntity {
    init(_ equipment: Equipment) {
        self.init(id: equipment.id, name: equipment.name)
    }
}

extension EffectEntity {
    init(_ effect: Effect) {
        self.init(id: effect.id, name: effect.name)
    }
}

extension EnvironmentEntity {
    init(_ environment: RoutingEnvironment) {
        self.init(id: environment.id, name: environment.name)
    }
}
