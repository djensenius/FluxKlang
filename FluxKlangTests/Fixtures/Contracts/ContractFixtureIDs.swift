//
//  ContractFixtureIDs.swift
//  FluxKlangTests
//
//  Fixed identities, fixture states and bounded ID sequences for the pure
//  contract doubles. Nothing here reads the wall clock or generates random IDs.
//

@testable import FluxKlang

/// Fixed identities shared by every contract fixture.
enum ContractFixtureIDs {
    static let host = HostID(validated: "fx.host")
    static let device = DeviceID(validated: "fx.device")
    static let primaryClock = ClockID(validated: "fx.clock.primary")
    static let musicalClock = ClockID(validated: "fx.clock.musical")
    static let action = ActionID(validated: "fx.action")
    static let capability = CapabilityID(validated: "fx.capability")
    static let stream = StreamID(validated: "fx.stream")
}

/// The states every fixture family must be able to express.
enum ContractFixtureState: String, CaseIterable, Hashable, Sendable {
    case available, missing, stale, failed, pressured
}

/// Why a sequence was not created or refused an ID. A refusal changes nothing.
enum FixtureIDSequenceError: Error, Equatable, Sendable {
    /// The prefix is empty, has a character outside the contract ID alphabet or
    /// would make the last ID longer than `ContractID.maximumLength`.
    case invalidPrefix
    case invalidLimit
    case exhausted
}

/// Hands out `fx.<prefix>.1` … `fx.<prefix>.<limit>` in order, then refuses.
struct FixtureIDSequence<Tag: ContractIDTag>: Hashable, Sendable {
    static var maximumLimit: Int { 4_096 }

    let prefix: String
    let limit: Int
    private(set) var issuedCount = 0

    init(prefix: String, limit: Int) throws(FixtureIDSequenceError) {
        guard (1...Self.maximumLimit).contains(limit) else { throw .invalidLimit }
        guard !prefix.isEmpty, (try? ContractID<Tag>.validate(Self.raw(prefix, limit))) != nil else {
            throw .invalidPrefix
        }
        self.prefix = prefix
        self.limit = limit
    }

    mutating func next() throws(FixtureIDSequenceError) -> ContractID<Tag> {
        guard issuedCount < limit else { throw .exhausted }
        guard let id = ContractID<Tag>(rawValue: Self.raw(prefix, issuedCount + 1)) else { throw .invalidPrefix }
        issuedCount += 1
        return id
    }

    private static func raw(_ prefix: String, _ index: Int) -> String {
        "fx.\(prefix).\(index)"
    }
}
