import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Controller source availability (#87, CSA1): which bindings have their controller origin listed as live. Every
/// fixture is a private static of the suite, so no name leaves it. Golden values are typed by hand.
@Suite("Control source availability")
struct ControlSourceAvailabilityTests {
    private static let pad70 = "midi.csa-pad.1.cc.70"
    private static let pad14 = "midi.csa-pad.2.cc14.7"
    private static let padBend = "midi.csa-pad.16.bend.0"
    private static let fader71 = "midi.csa-fader.1.cc.71"
    private static let aSource = "midi.csa-a.1.cc.70"
    private static let bSource = "midi.csa-b.1.cc.70"

    private static func binding(_ id: String, source: String) throws -> ControlBinding {
        try ControlBinding(.init(
            id: BindingID(id), source: ControlSourceID(source), target: ParameterID(validated: "par.csa.level"),
            unit: .percent, profile: .absolute(resolution: 128), pickup: .jump
        ))
    }

    private static func origin(_ token: String) throws -> ControlSourceOrigin {
        try ControlSourceOrigin(token)
    }

    private static func origins(_ tokens: [String]) throws -> Set<ControlSourceOrigin> {
        var set = Set<ControlSourceOrigin>()
        for token in tokens { set.insert(try origin(token)) }
        return set
    }

    private static func pad(_ number: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: 4 - digits.count) + digits
    }

    /// `count` bindings `bnd.n0000...` on one origin; the last one repeats the id of the first when asked.
    private static func numbered(_ count: Int, repeatingFirst: Bool = false) throws -> [ControlBinding] {
        var list: [ControlBinding] = []
        for index in 0..<count {
            let number = repeatingFirst && index == count - 1 ? 0 : index
            list.append(try binding("bnd.n" + pad(number), source: pad70))
        }
        return list
    }

    /// One binding per source, ids `bnd.n0`, `bnd.n1`, ... in the order given.
    private static func indexed(_ sources: [String]) throws -> [ControlBinding] {
        var list: [ControlBinding] = []
        for (index, source) in sources.enumerated() { list.append(try binding("bnd.n\(index)", source: source)) }
        return list
    }

    private static func liveOrigins(_ count: Int) throws -> Set<ControlSourceOrigin> {
        var set = Set<ControlSourceOrigin>()
        for index in 0..<count { set.insert(try origin("csa-o-" + pad(index))) }
        return set
    }

    private static func ids(_ report: ControlSourceAvailabilityReport) -> [String] {
        report.entries.map { $0.binding.rawValue }
    }

    private static func statuses(_ report: ControlSourceAvailabilityReport) -> [ControlSourceAvailabilityStatus] {
        report.entries.map { $0.status }
    }

    private static func tokens(_ list: [ControlSourceOrigin]) -> [String] {
        list.map { $0.token }
    }

    private static func refusal(
        _ bindings: [ControlBinding], _ live: Set<ControlSourceOrigin>
    ) -> ControlSourceAvailabilityRefusal? {
        do throws(ControlSourceAvailabilityRefusal) {
            _ = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: live)
            return nil
        } catch {
            return error
        }
    }

    @Test func controlSourceAvailabilityGoldenOneLiveOriginAndOneAbsentOrigin() throws {
        let bindings = try [Self.binding("bnd.a", source: Self.pad70), Self.binding("bnd.b", source: Self.fader71)]
        let report = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: Self.origins(["csa-pad"]))
        let fader = try Self.origin("csa-fader")
        let expected: [ControlSourceAvailabilityStatus] = [.available, .sourceAbsent(fader)]
        #expect(Self.ids(report) == ["bnd.a", "bnd.b"])
        #expect(Self.statuses(report) == expected)
        #expect(report.availableCount == 1)
        #expect(report.absentCount == 1)
        #expect(report.unjudgedCount == 0)
        #expect(Self.tokens(report.absentOrigins) == ["csa-fader"])
    }

    @Test func controlSourceAvailabilityPresenceFollowsTheOriginAndNotTheChannelKindOrNumber() throws {
        let bindings = try [
            Self.binding("bnd.a", source: Self.pad70), Self.binding("bnd.b", source: Self.pad14),
            Self.binding("bnd.c", source: Self.padBend)
        ]
        let live = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: Self.origins(["csa-pad"]))
        let none = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: [])
        let pad = try Self.origin("csa-pad")
        let allLive: [ControlSourceAvailabilityStatus] = [.available, .available, .available]
        let allAbsent: [ControlSourceAvailabilityStatus] = [.sourceAbsent(pad), .sourceAbsent(pad), .sourceAbsent(pad)]
        #expect(Self.statuses(live) == allLive)
        #expect(Self.statuses(none) == allAbsent)
    }

    @Test func controlSourceAvailabilityOriginsMatchByWholeTokenAndUnusedLiveOriginsAreNotListed() throws {
        let bindings = try [Self.binding("bnd.a", source: Self.pad70)]
        let pad = try Self.origin("csa-pad")
        let longer = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: Self.origins(["csa-pad2"]))
        let shorter = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: Self.origins(["csa-pa"]))
        let unused = try ControlSourceAvailability.project(
            bindings: bindings, liveOrigins: Self.origins(["csa-pad", "csa-zzz"])
        )
        let unusedOnly = try ControlSourceAvailability.project(
            bindings: bindings, liveOrigins: Self.origins(["csa-zzz"])
        )
        let absent: [ControlSourceAvailabilityStatus] = [.sourceAbsent(pad)]
        #expect(Self.statuses(longer) == absent)
        #expect(Self.statuses(shorter) == absent)
        #expect(Self.statuses(unused) == [.available])
        #expect(unused.absentOrigins.isEmpty)
        #expect(Self.tokens(unusedOnly.absentOrigins) == ["csa-pad"])
    }

    @Test func controlSourceAvailabilityEmptyInputsGiveAnEmptyReportAndAbsentEntries() throws {
        let nothing = try ControlSourceAvailability.project(bindings: [], liveOrigins: Self.origins(["csa-pad"]))
        let bare = try ControlSourceAvailability.project(bindings: [], liveOrigins: [])
        let bindings = try [Self.binding("bnd.a", source: Self.pad70), Self.binding("bnd.b", source: Self.fader71)]
        let silent = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: [])
        #expect(nothing.entries.isEmpty)
        #expect(nothing.absentOrigins.isEmpty)
        let total = nothing.availableCount + nothing.absentCount + nothing.unjudgedCount
        #expect(total == 0)
        #expect(bare.entries.isEmpty)
        #expect(Self.ids(silent) == ["bnd.a", "bnd.b"])
        #expect(silent.absentCount == 2)
        #expect(Self.tokens(silent.absentOrigins) == ["csa-fader", "csa-pad"])
    }

    @Test func controlSourceAvailabilitySourcesWithoutTheMidiPrefixAreNotMIDISources() throws {
        let sources = ["ctl.csa.test", "osc.csa.fader", "mid.csa-pad.1.cc.70"]
        let bindings = try Self.indexed(sources)
        let silent = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: [])
        let live = try ControlSourceAvailability.project(
            bindings: bindings, liveOrigins: Self.origins(["csa-pad", "ctl", "osc", "mid"])
        )
        let expected: [ControlSourceAvailabilityStatus] = [.notMIDISource, .notMIDISource, .notMIDISource]
        #expect(Self.statuses(silent) == expected)
        #expect(Self.statuses(live) == expected)
        #expect(silent.unjudgedCount == 3)
        #expect(silent.absentCount == 0)
        #expect(silent.availableCount == 0)
        #expect(silent.absentOrigins.isEmpty)
    }

    @Test func controlSourceAvailabilityMalformedMidiSourcesAreNeitherAvailableNorAbsent() throws {
        let sources = [
            "midi.csa-pad.1.cc.07", "midi.csa-pad.17.cc.1", "midi.Csa-Pad.1.cc.1", "midi.csa-pad.1.cc.1.5",
            "midi.csa-pad.1.xx.1", "midi.csa-pad.1.cc.200", "midi."
        ]
        let bindings = try Self.indexed(sources)
        let report = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: Self.origins(["csa-pad"]))
        let expected = [ControlSourceAvailabilityStatus](repeating: .malformedSource, count: 7)
        #expect(Self.statuses(report) == expected)
        #expect(report.unjudgedCount == 7)
        #expect(report.availableCount == 0)
        #expect(report.absentCount == 0)
        #expect(report.absentOrigins.isEmpty)
    }

    @Test func controlSourceAvailabilityEntriesAscendByBindingIdBytesWhateverTheInputOrder() throws {
        let forward = try [
            Self.binding("bnd.c", source: Self.pad70), Self.binding("bnd.a", source: Self.pad70),
            Self.binding("bnd.b", source: Self.pad70)
        ]
        let live = try Self.origins(["csa-pad"])
        let first = try ControlSourceAvailability.project(bindings: forward, liveOrigins: live)
        let second = try ControlSourceAvailability.project(bindings: forward.reversed(), liveOrigins: live)
        let cased = try [
            Self.binding("bnd.B", source: Self.pad70), Self.binding("bnd.a", source: Self.pad70),
            Self.binding("bnd.A", source: Self.pad70)
        ]
        let third = try ControlSourceAvailability.project(bindings: cased, liveOrigins: live)
        let caseTwins = try [Self.binding("bnd.a", source: Self.pad70), Self.binding("bnd.A", source: Self.pad70)]
        let fourth = try ControlSourceAvailability.project(bindings: caseTwins, liveOrigins: live)
        #expect(Self.ids(first) == ["bnd.a", "bnd.b", "bnd.c"])
        #expect(first == second)
        #expect(Self.ids(third) == ["bnd.A", "bnd.B", "bnd.a"])
        #expect(Self.ids(fourth) == ["bnd.A", "bnd.a"])
    }

    @Test func controlSourceAvailabilityAbsentOriginsAreDistinctAndAscending() throws {
        var bindings = [try Self.binding("bnd.live", source: Self.pad70)]
        for letter in ["h", "d", "f", "b", "g", "c", "e", "a"] {
            let source = "midi.csa-" + letter + ".1.cc.70"
            bindings.append(try Self.binding("bnd." + letter + "1", source: source))
            bindings.append(try Self.binding("bnd." + letter + "2", source: source))
        }
        let report = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: Self.origins(["csa-pad"]))
        let expected = ["csa-a", "csa-b", "csa-c", "csa-d", "csa-e", "csa-f", "csa-g", "csa-h"]
        #expect(Self.tokens(report.absentOrigins) == expected)
        #expect(report.absentCount == 16)
    }

    @Test func controlSourceAvailabilityCountsSumToTheEntriesOfAMixedFixture() throws {
        let bindings = try [
            Self.binding("bnd.1", source: Self.pad70), Self.binding("bnd.2", source: Self.pad14),
            Self.binding("bnd.3", source: Self.aSource), Self.binding("bnd.4", source: Self.bSource),
            Self.binding("bnd.5", source: Self.fader71), Self.binding("bnd.6", source: "ctl.csa.test"),
            Self.binding("bnd.7", source: "midi.csa-pad.1.cc.07")
        ]
        let report = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: Self.origins(["csa-pad"]))
        let total = report.availableCount + report.absentCount + report.unjudgedCount
        #expect(report.entries.count == 7)
        #expect(report.availableCount == 2)
        #expect(report.absentCount == 3)
        #expect(report.unjudgedCount == 2)
        #expect(total == report.entries.count)
    }

    @Test func controlSourceAvailabilityARepeatedBindingIdIsRefusedAndTheSmallerRepeatIsNamed() throws {
        let live = try Self.origins(["csa-pad"])
        let single = try [
            Self.binding("bnd.x", source: Self.pad70), Self.binding("bnd.y", source: Self.pad70),
            Self.binding("bnd.x", source: Self.fader71)
        ]
        let two = try [
            Self.binding("bnd.m", source: Self.pad70), Self.binding("bnd.b", source: Self.pad70),
            Self.binding("bnd.m", source: Self.pad70), Self.binding("bnd.b", source: Self.pad70)
        ]
        let repeated = try BindingID("bnd.x")
        let smaller = try BindingID("bnd.b")
        #expect(Self.refusal(single, live) == .duplicateBinding(repeated))
        #expect(Self.refusal(two, live) == .duplicateBinding(smaller))
    }

    @Test func controlSourceAvailabilityTheBindingAndOriginCapsAcceptTheLimitAndRefuseOneMore() throws {
        let maxBindings = ControlBindingLimit.maximumBindings
        let maxOrigins = ControlSourceAvailability.maximumLiveOrigins
        let one = try [Self.binding("bnd.a", source: Self.pad70)]
        let belowBindings = try Self.numbered(maxBindings - 1)
        let fullBindings = try Self.numbered(maxBindings)
        let overBindings = try Self.numbered(maxBindings + 1)
        let below = try ControlSourceAvailability.project(bindings: belowBindings, liveOrigins: [])
        let full = try ControlSourceAvailability.project(bindings: fullBindings, liveOrigins: [])
        let belowOrigins = try Self.liveOrigins(maxOrigins - 1)
        let fullOrigins = try Self.liveOrigins(maxOrigins)
        let overOrigins = try Self.liveOrigins(maxOrigins + 1)
        let narrow = try ControlSourceAvailability.project(bindings: one, liveOrigins: belowOrigins)
        let wide = try ControlSourceAvailability.project(bindings: one, liveOrigins: fullOrigins)
        #expect(below.entries.count == maxBindings - 1)
        #expect(full.entries.count == maxBindings)
        #expect(narrow.entries.count == 1)
        #expect(wide.entries.count == 1)
        #expect(Self.refusal(overBindings, []) == .tooManyBindings(maxBindings + 1))
        #expect(Self.refusal(one, overOrigins) == .tooManyLiveOrigins(maxOrigins + 1))
    }

    @Test func controlSourceAvailabilityRefusalsAreCheckedInTheOrderBindingsOriginsDuplicates() throws {
        let overBindings = ControlBindingLimit.maximumBindings + 1
        let overOrigins = ControlSourceAvailability.maximumLiveOrigins + 1
        let manyBindings = try Self.numbered(overBindings)
        let manyAndDuplicated = try Self.numbered(overBindings, repeatingFirst: true)
        let few = try Self.numbered(3, repeatingFirst: true)
        let manyOrigins = try Self.liveOrigins(overOrigins)
        #expect(Self.refusal(manyBindings, manyOrigins) == .tooManyBindings(overBindings))
        #expect(Self.refusal(manyAndDuplicated, []) == .tooManyBindings(overBindings))
        #expect(Self.refusal(few, manyOrigins) == .tooManyLiveOrigins(overOrigins))
    }

    @Test func controlSourceAvailabilityEntriesCarryTheBindingIdAndSourceIdOfTheirBinding() throws {
        let bindings = try [
            Self.binding("bnd.c", source: Self.fader71), Self.binding("bnd.a", source: Self.pad70),
            Self.binding("bnd.b", source: Self.pad14)
        ]
        let report = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: Self.origins(["csa-pad"]))
        let sources = report.entries.map { $0.source.rawValue }
        #expect(Self.ids(report) == ["bnd.a", "bnd.b", "bnd.c"])
        #expect(sources == [Self.pad70, Self.pad14, Self.fader71])
    }

    @Test func controlSourceAvailabilityEqualInputsGiveEqualReportsInAnyInputOrder() throws {
        let bindings = try [
            Self.binding("bnd.a", source: Self.pad70), Self.binding("bnd.b", source: Self.fader71),
            Self.binding("bnd.c", source: "ctl.csa.test")
        ]
        let live = try Self.origins(["csa-pad"])
        let once = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: live)
        let twice = try ControlSourceAvailability.project(bindings: bindings, liveOrigins: live)
        let reversed = try ControlSourceAvailability.project(bindings: bindings.reversed(), liveOrigins: live)
        #expect(once == twice)
        #expect(once == reversed)
    }

    @Test func controlSourceAvailabilityARefusedCallDoesNotSpoilALaterValidCall() throws {
        let live = try Self.origins(["csa-pad"])
        let good = try [Self.binding("bnd.a", source: Self.pad70), Self.binding("bnd.b", source: Self.fader71)]
        let bad = try [Self.binding("bnd.a", source: Self.pad70), Self.binding("bnd.a", source: Self.pad70)]
        let fader = try Self.origin("csa-fader")
        let expected: [ControlSourceAvailabilityStatus] = [.available, .sourceAbsent(fader)]
        #expect(Self.refusal(bad, live) != nil)
        let report = try ControlSourceAvailability.project(bindings: good, liveOrigins: live)
        #expect(Self.statuses(report) == expected)
    }
}
