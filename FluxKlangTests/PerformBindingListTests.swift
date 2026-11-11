import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The perform "Bindings..." list (#102 PBL1): one row per binding of a pickup book, its exact text, the stale
/// controller rule, the UTF-8 byte order and the refusal order. Every fixture is a private static of the suite and
/// every expected text is typed by hand. Pure values only: no device, clock, store or I/O.
#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct PerformBindingListTests {
    private static let knobSource = ControlSourceID(validated: "midi.ctl-a.1.cc.70")
    private static let encoderSource = ControlSourceID(validated: "midi.ctl-a.1.cc.71")
    private static let faderSource = ControlSourceID(validated: "midi.ctl-b.1.cc.72")
    private static let docLabels: [ControlSourceID: String] = [
        knobSource: "Knob 1", encoderSource: "Encoder 2", faderSource: "Fader 3"
    ]
    private static let staleTail = "Unavailable. Unavailable: controller stale"

    private static func absolute(
        _ id: String, _ source: ControlSourceID, target: String = "par.pbl.x", mode: PickupMode = .catch,
        resolution: Int = 128
    ) throws -> ControlBinding {
        try ControlBinding(.init(
            id: BindingID(id), source: source, target: ParameterID(target), unit: .percent,
            profile: .absolute(resolution: resolution), pickup: mode
        ))
    }

    private static func relative(
        _ id: String, _ source: ControlSourceID, target: String = "par.pbl.x"
    ) throws -> ControlBinding {
        try ControlBinding(.init(
            id: BindingID(id), source: source, target: ParameterID(target), unit: .decibels,
            profile: .twosComplement(width: .seven), step: 0.5
        ))
    }

    private static func source(_ raw: String) throws -> ControlSourceID {
        try ControlSourceID(raw)
    }

    private static func group(_ id: String, _ members: [String]) throws -> ControlBindingGroup {
        try ControlBindingGroup(.init(id: BindingGroupID(id), members: members.map { try BindingID($0) }))
    }

    private static func book(
        _ bindings: [ControlBinding], states: [BindingID: PickupState] = [:], lost: [ControlSourceID] = []
    ) throws -> ControlPickupBook {
        var book = ControlPickupBook()
        for binding in bindings { try book.add(binding) }
        try book.record(states)
        for source in lost { book.sourceLost(source) }
        return book
    }

    private static func report(_ bindings: [ControlBinding], live: [String]) throws -> ControlSourceAvailabilityReport {
        var origins = Set<ControlSourceOrigin>()
        for token in live { origins.insert(try ControlSourceOrigin(token)) }
        return try ControlSourceAvailability.project(bindings: bindings, liveOrigins: origins)
    }

    private static func list(
        _ book: ControlPickupBook, live: [String], groups: [ControlBindingGroup] = [],
        dialects: [String: ControlIntakeDialect] = [:], labels: [ControlSourceID: String] = [:]
    ) throws -> PerformBindingList {
        var feedback: [ControlSourceOrigin: ControlIntakeDialect] = [:]
        for (token, dialect) in dialects {
            let origin = try ControlSourceOrigin(token)
            feedback[origin] = dialect
        }
        return try PerformBindingList.make(
            book: book, groups: groups, availability: report(book.entries.map(\.binding), live: live),
            feedbackDialects: feedback, controlLabels: labels
        )
    }

    private static func refusal(
        _ book: ControlPickupBook, _ availability: ControlSourceAvailabilityReport,
        groups: [ControlBindingGroup] = [], labels: [ControlSourceID: String] = [:]
    ) -> PerformBindingListRefusal? {
        do throws(PerformBindingListRefusal) {
            _ = try PerformBindingList.make(
                book: book, groups: groups, availability: availability, feedbackDialects: [:], controlLabels: labels
            )
            return nil
        } catch {
            return error
        }
    }

    private static func texts(_ list: PerformBindingList) -> [String] {
        list.rows.map(\.showBindingText)
    }

    private static func ids(_ list: PerformBindingList) -> [String] {
        list.rows.map(\.binding.rawValue)
    }

    private struct FeedbackCase {
        let binding: ControlBinding
        let paired: PerformBindingFeedback
        let sevenBit: PerformBindingFeedback
    }

    private struct PickupCase {
        let binding: ControlBinding
        let mode: PickupMode?
        let status: PerformBindingPickupStatus
        let part: String
    }

    @Test func performDocExampleRowsReadTheirExactText() throws {
        let book = try Self.book([
            Self.absolute("bnd.knob1-mix", Self.knobSource, target: "par.verb.mix"),
            Self.relative("bnd.enc2-mains", Self.encoderSource, target: "par.mains.gain"),
            Self.absolute("bnd.fader3-width", Self.faderSource, target: "par.space.width")
        ], lost: [Self.knobSource])
        let list = try Self.list(book, live: ["ctl-b"], labels: Self.docLabels)
        #expect(Self.texts(list) == [
            "Encoder 2 on ctl-a: Stale. Target par.mains.gain. No group. No pickup (relative): " + Self.staleTail,
            "Fader 3 on ctl-b: Live. Target par.space.width. No group. Catch pickup: Waiting. Unsupported by device",
            "Knob 1 on ctl-a: Stale. Target par.verb.mix. No group. Catch pickup: " + Self.staleTail
        ])
    }

    @Test func eachFeedbackStateReadsItsExactWords() throws {
        #expect(PerformBindingFeedback.allCases.map(\.rawValue)
            == ["Sends feedback", "Unsupported by device", "Unavailable: controller stale"])
        let book = try Self.book([Self.absolute("bnd.fader3-width", Self.faderSource, target: "par.space.width")])
        let live = "Fader 3 on ctl-b: Live. Target par.space.width. No group. Catch pickup: Waiting. "
        let labels = Self.docLabels
        let sends = try Self.list(book, live: ["ctl-b"], dialects: ["ctl-b": .pairedFourteenBit], labels: labels)
        #expect(Self.texts(sends) == [live + "Sends feedback"])
        let unlisted = try Self.list(book, live: ["ctl-b"], dialects: ["ctl-a": .msbOnlySevenBit], labels: labels)
        #expect(Self.texts(unlisted) == [live + "Unsupported by device"])
        let stale = try Self.list(book, live: ["ctl-a"], dialects: ["ctl-b": .pairedFourteenBit], labels: labels)
        #expect(Self.texts(stale)
            == ["Fader 3 on ctl-b: Stale. Target par.space.width. No group. Catch pickup: " + Self.staleTail])
    }

    @Test func feedbackIsSentOnlyToControlsTheEncoderCanAddress() throws {
        let cases = try [
            FeedbackCase(binding: Self.absolute("bnd.cc", Self.source("midi.ctl-b.1.cc.72")), paired: .sends,
                         sevenBit: .sends),
            FeedbackCase(binding: Self.relative("bnd.relative", Self.source("midi.ctl-b.1.cc.73")),
                         paired: .unsupportedByDevice, sevenBit: .unsupportedByDevice),
            FeedbackCase(binding: Self.absolute("bnd.cc14", Self.source("midi.ctl-b.1.cc14.7"), resolution: 16_384),
                         paired: .sends, sevenBit: .unsupportedByDevice),
            FeedbackCase(binding: Self.absolute("bnd.rpn", Self.source("midi.ctl-b.1.rpn.5"), resolution: 16_384),
                         paired: .unsupportedByDevice, sevenBit: .unsupportedByDevice),
            FeedbackCase(binding: Self.absolute("bnd.msb", Self.source("midi.ctl-b.1.cc.20")),
                         paired: .unsupportedByDevice, sevenBit: .sends),
            FeedbackCase(binding: Self.absolute("bnd.wide", Self.source("midi.ctl-b.1.cc.74"), resolution: 16_384),
                         paired: .unsupportedByDevice, sevenBit: .unsupportedByDevice),
            FeedbackCase(binding: Self.absolute("bnd.bend", Self.source("midi.ctl-b.1.bend.0"), resolution: 16_384),
                         paired: .sends, sevenBit: .sends)
        ]
        let book = try Self.book(cases.map { $0.binding })
        let paired = try Self.list(book, live: ["ctl-b"], dialects: ["ctl-b": .pairedFourteenBit])
        let sevenBit = try Self.list(book, live: ["ctl-b"], dialects: ["ctl-b": .msbOnlySevenBit])
        for item in cases {
            let pairedRow = try #require(paired.row(for: item.binding.id))
            let sevenBitRow = try #require(sevenBit.row(for: item.binding.id))
            #expect(pairedRow.feedback == item.paired, "\(item.binding.id)")
            #expect(sevenBitRow.feedback == item.sevenBit, "\(item.binding.id)")
        }
    }

    @Test func aStaleControllersRowsStayListedAsStaleUntilSeenAgain() throws {
        let lostByBook = try Self.absolute("bnd.a", Self.knobSource)
        let liveJump = try Self.absolute("bnd.b", Self.encoderSource, mode: .jump)
        let absentInReport = try Self.absolute("bnd.c", Self.faderSource)
        var book = try Self.book(
            [lostByBook, liveJump, absentInReport], states: [absentInReport.id: .engaged(hardware: 0.4)],
            lost: [Self.knobSource]
        )
        let dialects: [String: ControlIntakeDialect] = ["ctl-a": .pairedFourteenBit, "ctl-b": .pairedFourteenBit]
        let list = try Self.list(book, live: ["ctl-a"], dialects: dialects)
        #expect(Self.ids(list) == ["bnd.a", "bnd.b", "bnd.c"])
        #expect(Self.texts(list) == [
            "midi.ctl-a.1.cc.70 on ctl-a: Stale. Target par.pbl.x. No group. Catch pickup: " + Self.staleTail,
            "midi.ctl-a.1.cc.71 on ctl-a: Live. Target par.pbl.x. No group. Jump pickup: Engaged. Sends feedback",
            "midi.ctl-b.1.cc.72 on ctl-b: Stale. Target par.pbl.x. No group. Catch pickup: " + Self.staleTail
        ])
        // Deliberately conservative: the report says ctl-b is absent but the book still holds bnd.c engaged (no
        // sourceLost yet), so the dispatchers would still apply its input. The row shows no pickup or feedback anyway.
        let engagedInBook = try #require(list.row(for: absentInReport.id))
        #expect(book.state(of: absentInReport.id) == .engaged(hardware: 0.4))
        #expect(engagedInBook.presence == .stale)
        #expect(engagedInBook.pickupStatus == .unavailable)
        #expect(engagedInBook.feedback == .controllerStale)
        book.sourceSeen(Self.knobSource)
        let seen = try Self.list(book, live: ["ctl-a", "ctl-b"], dialects: dialects)
        #expect(seen.rows.map(\.presence) == [.live, .live, .live])
        #expect(seen.rows.map(\.pickupStatus) == [.waiting, .engaged, .engaged])
        #expect(seen.rows.map(\.feedback) == [.sends, .sends, .sends])
    }

    @Test func rowsOrderByGroupThenControlThenBindingIDBytes() throws {
        #expect("é" == "e\u{301}")
        #expect(!"é".utf8.elementsEqual("e\u{301}".utf8))
        let shared = try Self.source("midi.ctl-a.1.cc.90")
        var bindings = try [
            Self.absolute("bnd.g1", Self.source("midi.ctl-b.1.cc.65")),
            Self.absolute("bnd.g2", Self.source("midi.ctl-b.1.cc.66")),
            Self.absolute("bnd.g3", Self.source("midi.ctl-b.1.cc.67"))
        ]
        let labelled = ["é", "e\u{301}", "f", "Z", "Knob 10", "Knob 2"]
        var labels: [ControlSourceID: String] = try [
            Self.source("midi.ctl-b.1.cc.65"): "Zed", Self.source("midi.ctl-b.1.cc.66"): "Alpha",
            Self.source("midi.ctl-b.1.cc.67"): "Zulu"
        ]
        for (index, label) in labelled.enumerated() {
            let source = try Self.source("midi.ctl-b.1.cc.\(102 + index)")
            labels[source] = label
            bindings.append(try Self.absolute("bnd.u\(index + 1)", source))
        }
        for id in ["bnd.a_1", "bnd.aA", "bnd.a1", "bnd.a.1", "bnd.a-1", "bnd.a", "bnd.A"] {
            bindings.append(try Self.absolute(id, shared))
        }
        let groups = try [Self.group("grp.a", ["bnd.g1", "bnd.g2"]), Self.group("grp.B", ["bnd.g3"])]
        let expected = [
            "bnd.g3", "bnd.g2", "bnd.g1", "bnd.u5", "bnd.u6", "bnd.u4", "bnd.u2", "bnd.u3",
            "bnd.A", "bnd.a", "bnd.a-1", "bnd.a.1", "bnd.a1", "bnd.aA", "bnd.a_1", "bnd.u1"
        ]
        let list = try Self.list(Self.book(bindings), live: ["ctl-b"], groups: groups, labels: labels)
        #expect(Self.ids(list) == expected)
        let reversed = try Self.list(
            Self.book(bindings.reversed()), live: ["ctl-b"], groups: groups.reversed(), labels: labels
        )
        #expect(reversed == list)
        let first = try #require(list.rows.first)
        #expect(first.showBindingText
            == "Zulu on ctl-b: Live. Target par.pbl.x. Group grp.B. Catch pickup: Waiting. Unsupported by device")
        let last = try #require(list.rows.last)
        #expect(last.control == "é")
        #expect(last.group == nil)
    }

    @Test func showBindingTextIsTheRowTextForEveryRow() throws {
        let book = try Self.book([
            Self.absolute("bnd.knob1-mix", Self.knobSource, target: "par.verb.mix", mode: .jump),
            Self.relative("bnd.enc2-mains", Self.encoderSource, target: "par.mains.gain"),
            Self.absolute("bnd.fader3-width", Self.faderSource, target: "par.space.width"),
            Self.absolute("bnd.osc", Self.source("osc.knob.1"))
        ], lost: [Self.encoderSource])
        let groups = try [Self.group("grp.knob", ["bnd.knob1-mix"])]
        let list = try Self.list(
            book, live: ["ctl-a"], groups: groups, dialects: ["ctl-a": .pairedFourteenBit], labels: Self.docLabels
        )
        try #require(list.rows.count == 4)
        for row in list.rows {
            let mode = row.pickupMode?.performText ?? "No pickup (relative)"
            let parts = [
                "\(row.control) on \(row.device?.token ?? "unknown device"): \(row.presence.rawValue)",
                "Target \(row.target.rawValue)", row.group.map { "Group \($0.rawValue)" } ?? "No group",
                "\(mode): \(row.pickupStatus.rawValue)", row.feedback.rawValue
            ]
            #expect(row.showBindingText == parts.joined(separator: ". "))
            #expect(list.row(for: row.binding)?.showBindingText == row.showBindingText)
        }
        #expect(list.row(for: BindingID(validated: "bnd.missing")) == nil)
        #expect(list.rows[0].showBindingText
            == "Knob 1 on ctl-a: Live. Target par.verb.mix. Group grp.knob. Jump pickup: Engaged. Sends feedback")
    }

    @Test func pickupModeAndStateReadTheirWordsForEveryCase() throws {
        #expect(PerformBindingPickupStatus.allCases.map(\.rawValue) == ["Engaged", "Waiting", "Unavailable"])
        #expect(PerformBindingPresence.allCases.map(\.rawValue) == ["Live", "Stale", "Presence unknown"])
        #expect(PickupMode.allCases.map(\.performText) == ["Catch pickup", "Jump pickup"])
        let stale = try Self.source("midi.ctl-a.1.cc.80")
        let cases = try [
            PickupCase(binding: Self.absolute("bnd.c1", Self.source("midi.ctl-b.1.cc.81")), mode: .catch,
                       status: .engaged, part: "Catch pickup: Engaged"),
            PickupCase(binding: Self.absolute("bnd.c2", Self.source("midi.ctl-b.1.cc.82")), mode: .catch,
                       status: .waiting, part: "Catch pickup: Waiting"),
            PickupCase(binding: Self.absolute("bnd.c3", stale), mode: .catch, status: .unavailable,
                       part: "Catch pickup: Unavailable"),
            PickupCase(binding: Self.absolute("bnd.j1", Self.source("midi.ctl-b.1.cc.83"), mode: .jump), mode: .jump,
                       status: .engaged, part: "Jump pickup: Engaged"),
            PickupCase(binding: Self.absolute("bnd.j2", stale, mode: .jump), mode: .jump, status: .unavailable,
                       part: "Jump pickup: Unavailable"),
            PickupCase(binding: Self.relative("bnd.r1", Self.source("midi.ctl-b.1.cc.84")), mode: nil,
                       status: .engaged, part: "No pickup (relative): Engaged"),
            PickupCase(binding: Self.relative("bnd.r2", stale), mode: nil, status: .unavailable,
                       part: "No pickup (relative): Unavailable")
        ]
        let engaged = try BindingID("bnd.c1")
        let book = try Self.book(cases.map { $0.binding }, states: [engaged: .engaged(hardware: 0.5)], lost: [stale])
        let list = try Self.list(book, live: ["ctl-a", "ctl-b"])
        for item in cases {
            let row = try #require(list.row(for: item.binding.id))
            let parts = row.showBindingText.components(separatedBy: ". ")
            try #require(parts.count == 5)
            #expect(row.pickupMode == item.mode, "\(item.binding.id)")
            #expect(row.pickupStatus == item.status, "\(item.binding.id)")
            #expect(parts[3] == item.part, "\(item.binding.id)")
        }
    }

    @Test func aSourceTheLiveSetCannotJudgeHasAnUnknownDevice() throws {
        let osc = try Self.absolute("bnd.osc", Self.source("osc.knob.1"), mode: .jump)
        let malformed = try Self.absolute("bnd.zero", Self.source("midi.ctl-a.01.cc.70"), mode: .jump)
        let lost = try Self.absolute("bnd.lost", Self.source("osc.knob.2"), mode: .jump)
        let book = try Self.book([osc, malformed, lost], lost: [lost.source])
        let list = try Self.list(book, live: ["ctl-a"], dialects: ["ctl-a": .pairedFourteenBit])
        let unjudged = " on unknown device: Presence unknown. Target par.pbl.x. No group. Jump pickup: Engaged. "
        #expect(Self.texts(list) == [
            "midi.ctl-a.01.cc.70" + unjudged + "Unsupported by device",
            "osc.knob.1" + unjudged + "Unsupported by device",
            "osc.knob.2 on unknown device: Stale. Target par.pbl.x. No group. Jump pickup: " + Self.staleTail
        ])
        #expect(list.rows.map(\.device) == [nil, nil, nil])
    }

    @Test func refusalsComeInTheirDeclaredOrder() throws {
        let first = try Self.absolute("bnd.a", Self.knobSource)
        let second = try Self.absolute("bnd.b", Self.faderSource)
        let moved = try Self.absolute("bnd.b", Self.encoderSource)
        let renamed = try Self.absolute("bnd.c", Self.faderSource)
        let book = try Self.book([first, second])
        let good = try Self.report([first, second], live: [])
        let short = try Self.report([first], live: [])
        let otherSource = try Self.report([first, moved], live: [])
        let otherBinding = try Self.report([first, renamed], live: [])
        var groups = try [
            Self.group("grp.b", ["bnd.gone"]), Self.group("grp.a", ["bnd.a"]), Self.group("grp.c", ["bnd.a"]),
            Self.group("grp.d", ["bnd.b"]), Self.group("grp.d", ["bnd.b"])
        ]
        let crowd = try (0...PerformBindingList.maximumGroups).map { try Self.group("grp.n\($0)", ["bnd.a"]) }
        #expect(PerformBindingList.maximumGroups == ControlBindingLimit.maximumBindings)
        #expect(Self.refusal(book, short, groups: crowd) == .tooManyGroups(PerformBindingList.maximumGroups + 1))
        #expect(Self.refusal(book, short, groups: groups) == .availabilityCountMismatch(book: 2, report: 1))
        #expect(Self.refusal(book, otherSource, groups: groups) == .availabilityMismatch(second.id))
        #expect(Self.refusal(book, otherBinding, groups: groups) == .availabilityMismatch(second.id))
        #expect(Self.refusal(book, good, groups: groups) == .duplicateGroup(BindingGroupID(validated: "grp.d")))
        groups.removeLast()
        #expect(Self.refusal(book, good, groups: groups) == .unknownGroupMember(
            group: BindingGroupID(validated: "grp.b"), member: BindingID(validated: "bnd.gone")
        ))
        groups.removeFirst()
        let tooLong = String(repeating: "é", count: 65)
        let labels = [Self.knobSource: "", Self.faderSource: tooLong, Self.encoderSource: ""]
        #expect(Self.refusal(book, good, groups: groups, labels: labels) == .bindingInSeveralGroups(first.id))
        groups.removeLast(2)
        #expect(Self.refusal(book, good, groups: groups, labels: labels)
            == .invalidControlLabel(Self.knobSource, bytes: 0))
        let fixed = [Self.knobSource: "Knob 1", Self.faderSource: tooLong, Self.encoderSource: ""]
        #expect(Self.refusal(book, good, groups: groups, labels: fixed)
            == .invalidControlLabel(Self.faderSource, bytes: 130))
        let fits = [Self.knobSource: "Knob 1", Self.faderSource: String(repeating: "é", count: 64)]
        let list = try PerformBindingList.make(
            book: book, groups: groups, availability: good, feedbackDialects: [:], controlLabels: fits
        )
        #expect(list.rows.map(\.control) == ["Knob 1", String(repeating: "é", count: 64)])
        #expect(list.rows.map(\.group) == [BindingGroupID(validated: "grp.a"), nil])
        let empty = try PerformBindingList.make(
            book: ControlPickupBook(), groups: [], availability: Self.report([], live: []), feedbackDialects: [:],
            controlLabels: [:]
        )
        #expect(empty.rows.isEmpty)
    }

    @Test func groupRefusalsNameTheFirstOffenderInByteOrder() throws {
        let book = try Self.book([Self.absolute("bnd.a", Self.knobSource), Self.absolute("bnd.b", Self.faderSource)])
        let good = try Self.report(book.entries.map(\.binding), live: [])
        let duplicates = try ["grp.b", "grp.B", "grp.b", "grp.B"].map { try Self.group($0, ["bnd.a"]) }
        #expect(Self.refusal(book, good, groups: duplicates) == .duplicateGroup(BindingGroupID(validated: "grp.B")))
        let unknown = try [Self.group("grp.b", ["bnd.x"]), Self.group("grp.B", ["bnd.a", "bnd.z", "bnd.y"])]
        #expect(Self.refusal(book, good, groups: unknown) == .unknownGroupMember(
            group: BindingGroupID(validated: "grp.B"), member: BindingID(validated: "bnd.z")
        ))
        let shared = try [Self.group("grp.b", ["bnd.a"]), Self.group("grp.B", ["bnd.b", "bnd.a"])]
        #expect(Self.refusal(book, good, groups: shared) == .bindingInSeveralGroups(BindingID(validated: "bnd.a")))
    }

    @Test func unknownMembersAreCheckedInEveryGroupBeforeOverlaps() throws {
        let book = try Self.book([Self.absolute("bnd.a", Self.knobSource), Self.absolute("bnd.b", Self.faderSource)])
        let good = try Self.report(book.entries.map(\.binding), live: [])
        // The overlap on bnd.a shows at grp.b, earlier in byte order than grp.c, which holds the only unknown member.
        // One walk that checked both together would refuse the overlap first.
        let groups = try [
            Self.group("grp.c", ["bnd.b", "bnd.gone"]), Self.group("grp.b", ["bnd.a"]), Self.group("grp.a", ["bnd.a"])
        ]
        #expect(Self.refusal(book, good, groups: groups) == .unknownGroupMember(
            group: BindingGroupID(validated: "grp.c"), member: BindingID(validated: "bnd.gone")
        ))
        #expect(Self.refusal(book, good, groups: Array(groups.dropFirst()))
            == .bindingInSeveralGroups(BindingID(validated: "bnd.a")))
    }

    @Test func labelsAreCheckedInBindingIDOrderNotSourceOrder() throws {
        // bnd.a uses the ctl-b source and bnd.b the ctl-a source, so binding id order disagrees with source order and
        // with the unlabelled display order. Labels are checked in binding id order, the book's order.
        let book = try Self.book([Self.absolute("bnd.b", Self.knobSource), Self.absolute("bnd.a", Self.faderSource)])
        let good = try Self.report(book.entries.map(\.binding), live: [])
        #expect(Self.knobSource.rawValue.utf8.lexicographicallyPrecedes(Self.faderSource.rawValue.utf8))
        #expect(book.entries.map(\.binding.source) == [Self.faderSource, Self.knobSource])
        let unlabelled = try Self.list(book, live: [])
        #expect(Self.ids(unlabelled) == ["bnd.b", "bnd.a"])
        let tooLong = String(repeating: "x", count: 129)
        #expect(Self.refusal(book, good, labels: [Self.knobSource: "", Self.faderSource: tooLong])
            == .invalidControlLabel(Self.faderSource, bytes: 129))
        #expect(Self.refusal(book, good, labels: [Self.knobSource: "", Self.faderSource: "Fader 3"])
            == .invalidControlLabel(Self.knobSource, bytes: 0))
    }
}
