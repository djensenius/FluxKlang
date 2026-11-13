import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct ControlLearnConflictTests {
    typealias Learn = ControlLearnTests

    static let sameTarget = BindingID(validated: "bnd.a-size")
    static let sameBoth = BindingID(validated: "bnd.m-knob5-size")
    static let sameSource = BindingID(validated: "bnd.z-knob5-gain")
    static let unrelated = BindingID(validated: "bnd.x-other")

    @Test
    func proposalListsEveryConflictSortedAndDeterministic() throws {
        let expected = [
            LearnConflict(binding: Self.sameTarget, kind: .sameTarget),
            LearnConflict(binding: Self.sameBoth, kind: .sameSourceAndTarget),
            LearnConflict(binding: Self.sameSource, kind: .sameSource)
        ]
        for existing in [try Self.crowd(), try Self.crowd().reversed()] {
            var session = try Learn.listening()
            let hearing = try session.hear(Learn.knob5, present: [Learn.deviceA], existing: existing, now: 1)
            #expect(Learn.proposal(hearing)?.conflicts == expected)
            guard case .awaitingReview(let review) = session.phase else { Issue.record("not reviewing"); continue }
            #expect(review.conflictingBindings == existing.filter { $0.id != Self.unrelated }.sorted { $0.id < $1.id })
        }
        #expect(try LearnConflicts.find(source: Learn.encoder2.source, target: Learn.trim, in: Self.crowd()).isEmpty)
    }

    @Test
    func confirmRefusesConflictsByDefault() throws {
        var session = try Learn.reviewing(Learn.knob5, existing: Self.crowd())
        let before = session
        let conflicts = try LearnConflicts.find(source: Learn.knob5.source, target: Learn.size, in: Self.crowd())
        #expect(conflicts.count == 3)
        #expect(throws: LearnRefusal.conflicted(conflicts)) {
            try session.confirm(descriptor: Learn.sizeDescriptor(), existing: Self.crowd())
        }
        #expect(session == before)
    }

    @Test
    func replacingExactlyTheConflictSetCommits() throws {
        var session = try Learn.reviewing(Learn.knob5, existing: Self.crowd())
        let named: Set = [Self.sameSource, Self.sameTarget, Self.sameBoth]
        var current = try Self.crowd().reversed().map { binding in
            var fields = binding.fields
            if binding.id == Self.unrelated { fields.pickup = .catch }
            return try ControlBinding(fields)
        }
        current.append(try Self.binding("bnd.extra", source: "ctl.extra", target: Learn.level))
        let commit = try session.confirm(.replace(named), descriptor: Learn.sizeDescriptor(), existing: current)
        #expect(commit.removing == [Self.sameTarget, Self.sameBoth, Self.sameSource])
        #expect(commit.binding.id == Learn.newID && session.phase == .committed(commit))
    }

    @Test
    func staleOrPartialReplacementIsRefused() throws {
        var session = try Learn.reviewing(Learn.knob5, existing: Self.crowd())
        let before = session
        let expected = [Self.sameTarget, Self.sameBoth, Self.sameSource]
        let attempts: [Set<BindingID>] = [
            [], [Self.sameTarget, Self.sameBoth], [Self.sameTarget, Self.sameBoth, Self.sameSource, Self.unrelated]
        ]
        for named in attempts {
            #expect(throws: LearnRefusal.staleReplacement(expected: expected, found: named.sorted())) {
                try session.confirm(.replace(named), descriptor: Learn.sizeDescriptor(), existing: Self.crowd())
            }
        }
        #expect(session == before)
        var clear = try Learn.reviewing(Learn.knob5)
        #expect(throws: LearnRefusal.staleReplacement(expected: [], found: [Self.sameTarget])) {
            try clear.confirm(.replace([Self.sameTarget]), descriptor: Learn.sizeDescriptor(), existing: [])
        }
        #expect(try clear.confirm(.replace([]), descriptor: Learn.sizeDescriptor(), existing: []).removing.isEmpty)
    }

    @Test
    func conflictsAreRecomputedAtConfirm() throws {
        var session = try Learn.reviewing(Learn.knob5, existing: Self.crowd())
        let before = session
        let current = try Self.crowd().filter { $0.id == Self.unrelated || $0.id == Self.sameTarget }
        let proposed: Set = [Self.sameSource, Self.sameTarget, Self.sameBoth]
        #expect(throws: LearnRefusal.staleReplacement(expected: [Self.sameTarget], found: proposed.sorted())) {
            try session.confirm(.replace(proposed), descriptor: Learn.sizeDescriptor(), existing: current)
        }
        #expect(throws: LearnRefusal.staleReview) {
            try session.confirm(.replace([Self.sameTarget]), descriptor: Learn.sizeDescriptor(), existing: current)
        }
        #expect(session == before)
        try session.cancel()
        try session.start(Learn.sizeDescriptor(), binding: Learn.newID, policy: LearnEligibilityPolicy(),
                          timeoutTicks: 100, now: 2)
        let heard = try session.hear(Learn.knob5, present: [Learn.deviceA], existing: current, now: 3)
        #expect(try #require(Learn.proposal(heard)).conflicts == [
            LearnConflict(binding: Self.sameTarget, kind: .sameTarget)
        ])
        let commit = try session.confirm(.replace([Self.sameTarget]), descriptor: Learn.sizeDescriptor(),
                                         existing: current)
        #expect(commit.removing == [Self.sameTarget])
        #expect(session.phase == .committed(commit))
    }

    @Test
    func sameConflictIdentityWithChangedContentRequiresFreshReview() throws {
        let original = try Self.binding(Self.sameBoth.rawValue, source: "ctl.knob-5", target: Learn.size)
        for (profile, pickup) in [(EncoderProfile.absolute(resolution: 128), PickupMode.catch),
                                  (.absolute(resolution: 256), .jump)] {
            var session = try Learn.reviewing(Learn.knob5, existing: [original])
            let before = session
            let changed = try ControlBinding(.init(id: original.id, source: original.source, target: original.target,
                                                   unit: original.unit, profile: profile, pickup: pickup))
            let conflicts = try LearnConflicts.find(source: Learn.knob5.source, target: Learn.size, in: [changed])
            #expect(conflicts == [LearnConflict(binding: Self.sameBoth, kind: .sameSourceAndTarget)])
            #expect(throws: LearnRefusal.staleReview) {
                try session.confirm(.replace([Self.sameBoth]), descriptor: Learn.sizeDescriptor(), existing: [changed])
            }
            #expect(session == before)
            try session.cancel()
            try session.start(Learn.sizeDescriptor(), binding: Learn.newID, policy: LearnEligibilityPolicy(),
                              timeoutTicks: 100, now: 2)
            _ = try #require(Learn.proposal(session.hear(Learn.knob5, present: [Learn.deviceA],
                                                         existing: [changed], now: 3)))
            guard case .awaitingReview(let review) = session.phase else { Issue.record("not reviewing"); continue }
            #expect(review.conflictingBindings == [changed])
            let commit = try session.confirm(.replace([Self.sameBoth]), descriptor: Learn.sizeDescriptor(),
                                             existing: [changed])
            #expect(commit.removing == [Self.sameBoth] && session.phase == .committed(commit))
        }
    }

    @Test
    func existingBindingsAreBounded() throws {
        let limit = LearnConflicts.maximumExistingBindings
        let many = try (0...limit).map { try Self.binding("bnd.n\($0)", source: "ctl.n\($0)", target: Learn.level) }
        var session = try Learn.listening()
        let before = session
        #expect(throws: LearnRefusal.tooManyBindings(4097)) {
            try session.hear(Learn.knob5, present: [Learn.deviceA], existing: many, now: 1)
        }
        #expect(session == before)
        let atLimit = Array(many.dropLast())
        #expect(Learn.proposal(try session.hear(Learn.knob5, present: [Learn.deviceA], existing: atLimit,
                                                now: 1))?.conflicts.isEmpty == true)
        #expect(throws: LearnRefusal.tooManyBindings(4097)) {
            try session.confirm(descriptor: Learn.sizeDescriptor(), existing: many)
        }
        let shorter = Array(atLimit.dropLast())
        #expect(try session.confirm(descriptor: Learn.sizeDescriptor(), existing: shorter).removing.isEmpty)
    }

    @Test
    func confirmRefusesTheBindingThatWouldExceedTheSharedLimit() throws {
        let limit = ControlBindingLimit.maximumBindings
        let bulk = try Self.filler(limit)
        var full = try Learn.reviewing(Learn.knob5)
        let fullBefore = full
        #expect(throws: LearnRefusal.tooManyBindings(limit + 1)) {
            try full.confirm(descriptor: Learn.sizeDescriptor(), existing: bulk)
        }
        #expect(full == fullBefore)

        var room = try Learn.reviewing(Learn.knob5)
        let below = Array(bulk.dropLast())
        #expect(try room.confirm(descriptor: Learn.sizeDescriptor(), existing: below).removing.isEmpty)

        let swapped = try Self.binding(Self.sameTarget.rawValue, source: "ctl.fader-1", target: Learn.size)
        var crowded = try Self.filler(limit - 1)
        crowded.append(swapped)
        var replacing = try Learn.reviewing(Learn.knob5, existing: crowded)
        let commit = try replacing.confirm(.replace([Self.sameTarget]), descriptor: Learn.sizeDescriptor(),
                                           existing: crowded)
        #expect(commit.removing == [Self.sameTarget])

        var refusing = try Learn.reviewing(Learn.knob5)
        let conflict = LearnConflict(binding: Self.sameTarget, kind: .sameTarget)
        #expect(throws: LearnRefusal.conflicted([conflict])) {
            try refusing.confirm(descriptor: Learn.sizeDescriptor(), existing: crowded)
        }
    }

    @Test
    func confirmReportsAnIdInUseBeforeTheSharedLimit() throws {
        let limit = ControlBindingLimit.maximumBindings
        var full = try Self.filler(limit - 1)
        full.append(try Self.binding(Learn.newID.rawValue, source: "ctl.other", target: Learn.level))
        var session = try Learn.reviewing(Learn.knob5)
        let before = session
        #expect(throws: LearnRefusal.bindingIDInUse(Learn.newID)) {
            try session.confirm(descriptor: Learn.sizeDescriptor(), existing: full)
        }
        #expect(session == before)
    }

    @Test
    func duplicateExistingBindingsAreRefused() throws {
        let twice = try [Self.binding("bnd.dup", source: "ctl.a", target: Learn.level),
                         Self.binding("bnd.dup", source: "ctl.b", target: Learn.level)]
        var session = try Learn.listening()
        #expect(throws: LearnRefusal.duplicateBinding(BindingID(validated: "bnd.dup"))) {
            try session.hear(Learn.knob5, present: [Learn.deviceA], existing: twice, now: 1)
        }
        #expect(session.phase.kind == .listening && session.lastTick == 0)
    }

    @Test
    func newBindingIDMustBeFreeUnlessReplaced() throws {
        let squatter = try Self.binding(Learn.newID.rawValue, source: "ctl.other", target: Learn.level)
        var session = try Learn.reviewing(Learn.knob5)
        #expect(throws: LearnRefusal.bindingIDInUse(Learn.newID)) {
            try session.confirm(descriptor: Learn.sizeDescriptor(), existing: [squatter])
        }
        let previous = try Self.binding(Learn.newID.rawValue, source: "ctl.knob-5", target: Learn.size)
        try session.cancel()
        try session.start(Learn.sizeDescriptor(), binding: Learn.newID, policy: LearnEligibilityPolicy(),
                          timeoutTicks: 100, now: 2)
        _ = try #require(Learn.proposal(session.hear(Learn.knob5, present: [Learn.deviceA],
                                                     existing: [previous], now: 3)))
        let commit = try session.confirm(.replace([Learn.newID]), descriptor: Learn.sizeDescriptor(),
                                         existing: [previous])
        #expect(commit.removing == [Learn.newID])
    }

    // MARK: - Helpers

    /// Bindings related to `ctl.knob-5` → `par.verb.size` in every way, listed out of order.
    static func crowd() throws -> [ControlBinding] {
        try [
            binding(sameSource.rawValue, source: "ctl.knob-5", target: Learn.level),
            binding(unrelated.rawValue, source: "ctl.knob-9", target: Learn.level),
            binding(sameBoth.rawValue, source: "ctl.knob-5", target: Learn.size),
            binding(sameTarget.rawValue, source: "ctl.fader-1", target: Learn.size)
        ]
    }

    /// `count` bindings `bnd.f<index>` on sources `ctl.f<index>` that conflict with nothing the Learn fixtures propose.
    static func filler(_ count: Int) throws -> [ControlBinding] {
        try (0..<count).map { try binding("bnd.f\($0)", source: "ctl.f\($0)", target: Learn.level) }
    }

    static func binding(_ id: String, source: String, target: ParameterID) throws -> ControlBinding {
        try ControlBinding(.init(id: BindingID(id), source: ControlSourceID(source), target: target,
                                 unit: .normalized, profile: .absolute(resolution: 128), pickup: .jump))
    }
}
