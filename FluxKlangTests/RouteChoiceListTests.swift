//
//  RouteChoiceListTests.swift
//  FluxKlangTests
//
//  The compact route picker's list as a value (#100 MAP1): rows in the source's order, the heading, the channel
//  text, the disabled output rows that another live route writes, shared inputs that stay enabled, the parity of the
//  hand-written claimant test with `RigChannelOverlapScan`, the accessibility labels, the truncation and empty
//  lines, names shown as given, and every refusal with its check order. The list is a pure value: nothing here
//  opens a view, a file or a clock.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Builders for the suite, all through the production API. Device ids are `dev.<x>` and are named `Interface <X>`.
enum RouteChoiceFixture {
    static func role(_ id: String) throws -> RoleID { try RoleID(id) }

    static func device(
        _ id: String, inputs: Int = 0, outputs: Int = 0, presence: DevicePresence = .present
    ) throws -> DeviceDescriptor {
        try DeviceDescriptor(
            id: DeviceID(id), kind: .audioInterface,
            layout: ChannelLayout(inputs: inputs, outputs: outputs, sampleRate: 48_000), binding: .reported,
            identity: DeviceIdentity(.init(uid: "uid-\(id)", evidence: [.deviceUID])), presence: presence
        )
    }

    static func source(
        _ role: String = "rol.cue", _ direction: RouteDirection = .output, width: Int = 2,
        on devices: [DeviceDescriptor]
    ) throws -> RigRoleCandidates {
        try RigRouteCandidates.candidates(
            for: RoleID(role), requirement: RouteRoleRequirement(direction: direction, channelCount: width),
            on: RigRouteCandidates.eligibleDevices(devices)
        )
    }

    static func route(
        _ id: String, _ role: String, _ device: String, _ direction: RouteDirection,
        _ channels: [Int], _ binding: RouteBinding = .confirmed
    ) throws -> AudioRoute {
        try AudioRoute(
            id: RouteID(id), role: RoleID(role), device: DeviceID(device), direction: direction,
            channels: channels, binding: binding
        )
    }

    /// An output route.
    static func route(
        _ id: String, _ role: String, _ device: String, _ channels: [Int], _ binding: RouteBinding = .confirmed
    ) throws -> AudioRoute {
        try route(id, role, device, .output, channels, binding)
    }

    /// "Interface P" for `dev.p`.
    static func names(for devices: [DeviceDescriptor]) -> [DeviceID: String] {
        Dictionary(uniqueKeysWithValues: devices.map {
            ($0.id, "Interface " + ($0.id.rawValue.last.map { String($0).uppercased() } ?? ""))
        })
    }

    static func labels() throws -> [RoleID: String] {
        [try role("rol.cue"): "Cue", try role("rol.mains"): "Mains", try role("rol.verb"): "Verb"]
    }

    static func make(
        _ direction: RouteDirection = .output, width: Int = 2, on devices: [DeviceDescriptor],
        routes: [AudioRoute] = [], names: [DeviceID: String]? = nil, labels: [RoleID: String]? = nil
    ) throws -> RouteChoiceList {
        try RouteChoiceList.make(
            role: role("rol.cue"), requirement: RouteRoleRequirement(direction: direction, channelCount: width),
            candidates: source("rol.cue", direction, width: width, on: devices), existingRoutes: routes,
            deviceNames: names ?? self.names(for: devices), roleLabels: labels ?? self.labels()
        )
    }

    static func states(_ list: RouteChoiceList) -> [RouteChoiceState] { list.rows.map(\.state) }
}

#if os(macOS)
@Suite("Route choice list", .productionAccessAudit)
#else
@Suite("Route choice list")
#endif
struct RouteChoiceListTests {
    typealias Fixture = RouteChoiceFixture

    @Test func aFreeStereoOutputRoleListsEveryBlockInSourceOrder() throws {
        let list = try Fixture.make(on: [Fixture.device("dev.p", outputs: 4)])
        #expect(list.role == (try Fixture.role("rol.cue")))
        #expect(list.headline == "Map Cue (2ch)")
        #expect(list.rows.map(\.candidate.firstChannel) == [0, 1, 2])
        #expect(list.rows.map(\.channelsText) == ["Out 1-2", "Out 2-3", "Out 3-4"])
        #expect(list.rows.map(\.deviceName) == ["Interface P", "Interface P", "Interface P"])
        #expect(list.rows.map(\.state) == [.available, .available, .available])
        #expect(list.rows.map(\.stateText) == ["available", "available", "available"])
        #expect(list.rows.map(\.isEnabled) == [true, true, true])
        #expect(list.rows.map(\.disabledReason) == [nil, nil, nil])
        #expect(list.rows.map(\.id) == list.rows.map(\.candidate))
        #expect(list.footnote == "Other hosts' devices are never listed (rigs are not synced)")
        #expect(list.emptyText == nil)
        #expect(list.truncationText == nil)
        #expect(!list.isTruncated)
    }

    @Test func rowsKeepTheSourceOrderAndNeverSortByName() throws {
        let devices = [try Fixture.device("dev.a", outputs: 2), try Fixture.device("dev.b", outputs: 2)]
        let names = [try DeviceID("dev.a"): "Zeta", try DeviceID("dev.b"): "Alpha"]
        let list = try Fixture.make(width: 1, on: devices, names: names)
        #expect(list.rows.map(\.deviceName) == ["Zeta", "Zeta", "Alpha", "Alpha"])
        #expect(list.rows.map(\.candidate.firstChannel) == [0, 1, 0, 1])
    }

    @Test func aMonoRoleAndAnInputRoleReadTheirChannels() throws {
        let mono = try Fixture.make(width: 1, on: [Fixture.device("dev.p", outputs: 2)])
        #expect(mono.headline == "Map Cue (1ch)")
        #expect(mono.rows.map(\.channelsText) == ["Out 1", "Out 2"])
        let input = try Fixture.make(.input, on: [Fixture.device("dev.p", inputs: 3)])
        #expect(input.rows.map(\.channelsText) == ["In 1-2", "In 2-3"])
    }

    @Test func anOutputAnotherConfirmedRouteWritesIsDisabledButListed() throws {
        let device = try Fixture.device("dev.p", outputs: 4)
        let mains = try Fixture.route("rte.mains", "rol.mains", "dev.p", [0, 1])
        let list = try Fixture.make(on: [device], routes: [mains])
        let mainsRole = try Fixture.role("rol.mains")
        #expect(list.rows.count == 3)
        #expect(Fixture.states(list) == [.outputInUse(by: [mainsRole]), .outputInUse(by: [mainsRole]), .available])
        #expect(list.rows.map(\.isEnabled) == [false, false, true])
        #expect(list.rows.map(\.disabledReason) == ["in use by Mains", "in use by Mains", nil])
        #expect(list.rows.map(\.stateText) == ["in use by Mains", "in use by Mains", "available"])
    }

    @Test func onlyLiveRoutesClaimAndTheTargetRolesOwnRouteNeverDoes() throws {
        let device = try Fixture.device("dev.p", outputs: 4)
        let proposed = try Fixture.route("rte.a", "rol.mains", "dev.p", [0, 1], .proposed)
        let claimed = try Fixture.make(on: [device], routes: [proposed])
        #expect(claimed.rows.map(\.isEnabled) == [false, false, true])

        let muted = try [
            Fixture.route("rte.a", "rol.mains", "dev.p", [0, 1], .stale),
            Fixture.route("rte.b", "rol.verb", "dev.p", [2, 3], .deviceMissing)
        ]
        let free = try Fixture.make(on: [device], routes: muted)
        #expect(free.rows.map(\.state) == [.available, .available, .available])

        let own = try Fixture.route("rte.own", "rol.cue", "dev.p", [0, 1])
        let replaced = try Fixture.make(on: [device], routes: [own])
        #expect(replaced.rows.map(\.state) == [.available, .available, .available])
        #expect(replaced.rows.map(\.isEnabled) == [true, true, true])
    }

    @Test func aRouteOnAnotherDeviceOrInTheOtherDirectionDoesNotClaim() throws {
        let devices = [try Fixture.device("dev.p", inputs: 4, outputs: 4), try Fixture.device("dev.q", outputs: 4)]
        let routes = try [
            Fixture.route("rte.a", "rol.mains", "dev.q", [0, 1]),
            Fixture.route("rte.b", "rol.verb", "dev.p", .input, [0, 1]),
            Fixture.route("rte.c", "rol.verb", "dev.p", [4, 5])
        ]
        let list = try Fixture.make(on: devices, routes: routes)
        #expect(list.rows.count == 6)
        #expect(list.rows.map(\.candidate.device.rawValue) == Array(repeating: "dev.p", count: 3)
            + Array(repeating: "dev.q", count: 3))
        let used = RouteChoiceState.outputInUse(by: [try Fixture.role("rol.mains")])
        #expect(list.rows.map(\.state) == [.available, .available, .available, used, used, .available])
    }

    @Test func anInputAnotherRouteReadsStaysEnabledAndClaimantsReadInIDByteOrder() throws {
        let device = try Fixture.device("dev.p", inputs: 4)
        let mains = try Fixture.route("rte.mains", "rol.mains", "dev.p", .input, [1])
        let shared = try Fixture.make(.input, on: [device], routes: [mains])
        let mainsRole = try Fixture.role("rol.mains")
        #expect(shared.rows.map(\.state) == [.sharedInput(by: [mainsRole]), .sharedInput(by: [mainsRole]), .available])
        #expect(shared.rows.map(\.isEnabled) == [true, true, true])
        #expect(shared.rows.map(\.disabledReason) == [nil, nil, nil])
        #expect(shared.rows.map(\.stateText) == ["also read by Mains", "also read by Mains", "available"])

        let routes = try [
            Fixture.route("rte.verb", "rol.verb", "dev.p", [0, 1, 2, 3], .proposed),
            Fixture.route("rte.m1", "rol.mains", "dev.p", [0]),
            Fixture.route("rte.m2", "rol.mains", "dev.p", [1])
        ]
        let two = try Fixture.make(on: [try Fixture.device("dev.p", outputs: 4)], routes: routes)
        let verb = try Fixture.role("rol.verb")
        #expect(two.rows.first?.state == .outputInUse(by: [mainsRole, verb]))
        #expect(two.rows.first?.stateText == "in use by Mains, Verb")
        #expect(two.rows.first?.disabledReason == "in use by Mains, Verb")
    }

    @Test func theClaimantTestAgreesWithTheOverlapScan() throws {
        let devices = [
            try Fixture.device("dev.p", inputs: 4, outputs: 4), try Fixture.device("dev.q", inputs: 4, outputs: 4)
        ]
        let routes = try [
            Fixture.route("rte.a", "rol.mains", "dev.p", [1, 2]),
            Fixture.route("rte.b", "rol.verb", "dev.q", [0], .proposed),
            Fixture.route("rte.c", "rol.mains", "dev.p", [3], .stale),
            Fixture.route("rte.d", "rol.verb", "dev.q", [2], .deviceMissing),
            Fixture.route("rte.e", "rol.mains", "dev.p", .input, [0]),
            Fixture.route("rte.f", "rol.verb", "dev.q", .input, [2, 3], .proposed)
        ]
        for direction in [RouteDirection.output, .input] {
            let list = try Fixture.make(direction, on: devices, routes: routes)
            #expect(list.rows.count == 6)
            for row in list.rows {
                let probe = try Fixture.route(
                    "rte.probe", "rol.cue", row.candidate.device.rawValue, direction, row.candidate.channels, .proposed
                )
                let probeID = try RouteID("rte.probe")
                let involved = RigChannelOverlapScan.overlaps(in: routes + [probe])
                    .filter { $0.routes.contains(probeID) }
                let conflict = involved.contains { $0.kind == .outputConflict }
                let shared = involved.contains { $0.kind == .sharedInput }
                if case .outputInUse = row.state { #expect(conflict && !shared) } else { #expect(!conflict) }
                if case .sharedInput = row.state { #expect(shared && !conflict) } else { #expect(!shared) }
            }
            #expect(list.rows.contains { $0.state != .available })
        }
    }

    @Test func theAccessibilityLabelsNameTheDeviceChannelsAndState() throws {
        let mains = try Fixture.route("rte.mains", "rol.mains", "dev.p", [0, 1])
        let list = try Fixture.make(on: [Fixture.device("dev.p", outputs: 4)], routes: [mains])
        let first = try #require(list.rows.first)
        let last = try #require(list.rows.last)
        #expect(first.accessibilityLabel == "Interface P, Out 1-2, in use by Mains, not selectable")
        #expect(last.accessibilityLabel == "Interface P, Out 3-4, available")
        let input = try Fixture.make(
            .input, on: [Fixture.device("dev.p", inputs: 2)],
            routes: [Fixture.route("rte.m", "rol.mains", "dev.p", .input, [0])]
        )
        #expect(input.rows.first?.accessibilityLabel == "Interface P, In 1-2, also read by Mains")
    }

    @Test func theSourcesTruncationIsCarriedAsAFlagAndOneLine() throws {
        let three = try ["dev.a", "dev.b", "dev.c"].map { try Fixture.device($0, outputs: 48) }
        let capped = try Fixture.make(width: 1, on: three)
        #expect(capped.rows.count == 64)
        #expect(capped.isTruncated)
        #expect(capped.truncationText == "80 more compatible choices are not listed")
        #expect(capped.emptyText == nil)

        let single = try Fixture.make(width: 1, on: [Fixture.device("dev.p", outputs: 65)])
        #expect(single.rows.count == 64)
        #expect(single.isTruncated)
        #expect(single.truncationText == "1 more compatible choice is not listed")

        let exact = try Fixture.make(width: 1, on: [Fixture.device("dev.p", outputs: 64)])
        #expect(exact.rows.count == 64)
        #expect(!exact.isTruncated)
        #expect(exact.truncationText == nil)
    }

    @Test func noCompatibleBlockGivesTheEmptyLine() throws {
        let tooNarrow = try Fixture.make(on: [Fixture.device("dev.p", outputs: 1)])
        #expect(tooNarrow.rows.isEmpty)
        #expect(tooNarrow.emptyText == "No compatible channels on the devices that are present")
        #expect(!tooNarrow.isTruncated)
        #expect(tooNarrow.truncationText == nil)
        #expect(tooNarrow.footnote == "Other hosts' devices are never listed (rigs are not synced)")

        let absent = try Fixture.make(on: [Fixture.device("dev.p", outputs: 4, presence: .missing)])
        #expect(absent.rows.isEmpty)
        #expect(absent.emptyText == "No compatible channels on the devices that are present")

        let none = try Fixture.make(on: [])
        #expect(none.rows.isEmpty)
        #expect(none.emptyText != nil)
    }

    @Test func namesAreShownAsGivenAndMissingOrBadOnesAreRefused() throws {
        let device = try Fixture.device("dev.p", outputs: 2)
        let id = try DeviceID("dev.p")
        let long = String(repeating: "n", count: 128)
        for name in ["  Padded Name  ", "mIxEd CaSe", long, "   "] {
            let list = try Fixture.make(on: [device], names: [id: name])
            #expect(list.rows.map(\.deviceName) == [name])
        }
        #expect(throws: RouteChoiceListRefusal.missingDeviceName(id)) {
            try Fixture.make(on: [device], names: [:])
        }
        #expect(throws: RouteChoiceListRefusal.invalidDeviceNameLength(id, bytes: 0)) {
            try Fixture.make(on: [device], names: [id: ""])
        }
        #expect(throws: RouteChoiceListRefusal.invalidDeviceNameLength(id, bytes: 129)) {
            try Fixture.make(on: [device], names: [id: long + "n"])
        }
        let cue = try Fixture.role("rol.cue")
        let mains = try Fixture.role("rol.mains")
        var labels = try Fixture.labels()
        labels[cue] = nil
        #expect(throws: RouteChoiceListRefusal.missingRoleLabel(cue)) {
            try Fixture.make(on: [device], labels: labels)
        }
        labels[cue] = ""
        #expect(throws: RouteChoiceListRefusal.invalidRoleLabelLength(cue, bytes: 0)) {
            try Fixture.make(on: [device], labels: labels)
        }
        labels[cue] = long + "n"
        #expect(throws: RouteChoiceListRefusal.invalidRoleLabelLength(cue, bytes: 129)) {
            try Fixture.make(on: [device], labels: labels)
        }
        labels = try Fixture.labels()
        labels[mains] = nil
        let claim = try Fixture.route("rte.m", "rol.mains", "dev.p", [0])
        #expect(throws: RouteChoiceListRefusal.missingRoleLabel(mains)) {
            try Fixture.make(on: [device], routes: [claim], labels: labels)
        }
        labels[mains] = ""
        #expect(throws: RouteChoiceListRefusal.invalidRoleLabelLength(mains, bytes: 0)) {
            try Fixture.make(on: [device], routes: [claim], labels: labels)
        }
        let unrelated = try Fixture.route("rte.m", "rol.mains", "dev.other", [0])
        #expect(try Fixture.make(on: [device], routes: [unrelated], labels: labels).rows.count == 1)
    }

    @Test func theOffenderIsTheSmallestIDByBytesAndTheChecksRunInOrder() throws {
        for count in 3...12 {
            let devices = try (0..<count).map {
                try Fixture.device("dev.\(Character(Unicode.Scalar(UInt8(97 + $0))))", outputs: 1)
            }
            let smallest = try #require(devices.first?.id)
            #expect(throws: RouteChoiceListRefusal.missingDeviceName(smallest)) {
                try Fixture.make(width: 1, on: devices, names: [:])
            }
            let empty = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, "") })
            #expect(throws: RouteChoiceListRefusal.invalidDeviceNameLength(smallest, bytes: 0)) {
                try Fixture.make(width: 1, on: devices, names: empty)
            }
        }
        let devices = [try Fixture.device("dev.a", outputs: 1), try Fixture.device("dev.B", outputs: 1)]
        let names = [try DeviceID("dev.a"): "A"]
        #expect(throws: RouteChoiceListRefusal.missingDeviceName(try DeviceID("dev.B"))) {
            try Fixture.make(width: 1, on: devices, names: names)
        }
        let mixed = [try DeviceID("dev.B"): ""]
        #expect(throws: RouteChoiceListRefusal.invalidDeviceNameLength(try DeviceID("dev.B"), bytes: 0)) {
            try Fixture.make(width: 1, on: devices, names: mixed)
        }

        let cue = try Fixture.role("rol.cue")
        let mains = try Fixture.role("rol.mains")
        let device = try Fixture.device("dev.p", outputs: 2)
        let id = try DeviceID("dev.p")
        let claim = try Fixture.route("rte.m", "rol.mains", "dev.p", [0])
        var labels = try Fixture.labels()
        labels[cue] = ""
        labels[mains] = nil
        #expect(throws: RouteChoiceListRefusal.invalidRoleLabelLength(cue, bytes: 0)) {
            try Fixture.make(on: [device], routes: [claim], names: [id: ""], labels: labels)
        }
        labels[cue] = "Cue"
        #expect(throws: RouteChoiceListRefusal.invalidDeviceNameLength(id, bytes: 0)) {
            try Fixture.make(on: [device], routes: [claim], names: [id: ""], labels: labels)
        }
        #expect(throws: RouteChoiceListRefusal.missingRoleLabel(mains)) {
            try Fixture.make(on: [device], routes: [claim], labels: labels)
        }
    }

    @Test func structuralInputsAreRefused() throws {
        let device = try Fixture.device("dev.p", outputs: 4)
        let route = try Fixture.route("rte.s", "rol.mains", "dev.z", [0], .stale)
        let accepted = try Fixture.make(on: [device], routes: Array(repeating: route, count: 4_096))
        #expect(accepted.rows.count == 3)
        #expect(throws: RouteChoiceListRefusal.tooManyRoutes(count: 4_097, maximum: 4_096)) {
            try Fixture.make(on: [device], routes: Array(repeating: route, count: 4_097))
        }
        var noLabels = try Fixture.labels()
        noLabels[try Fixture.role("rol.cue")] = nil
        #expect(throws: RouteChoiceListRefusal.tooManyRoutes(count: 4_097, maximum: 4_096)) {
            try Fixture.make(on: [device], routes: Array(repeating: route, count: 4_097), labels: noLabels)
        }

        let other = try Fixture.role("rol.other")
        let foreign = try Fixture.source("rol.other", on: [device])
        let output = RouteRoleRequirement(direction: .output, channelCount: 2)
        let names = Fixture.names(for: [device])
        let labels = try Fixture.labels()
        #expect(throws: RouteChoiceListRefusal.candidateForOtherRole(other)) {
            try RouteChoiceList.make(
                role: Fixture.role("rol.cue"), requirement: output, candidates: foreign,
                existingRoutes: [], deviceNames: names, roleLabels: labels
            )
        }
        let id = try DeviceID("dev.p")
        let wrongDirection = try Fixture.source("rol.cue", .input, on: [Fixture.device("dev.p", inputs: 4)])
        for misfit in [wrongDirection, try Fixture.source(width: 1, on: [device])] {
            #expect(throws: RouteChoiceListRefusal.candidateDoesNotFit(device: id, firstChannel: 0)) {
                try RouteChoiceList.make(
                    role: Fixture.role("rol.cue"), requirement: output, candidates: misfit,
                    existingRoutes: [], deviceNames: names, roleLabels: labels
                )
            }
        }
    }

    @Test func theCandidateChecksRunInOrderAndBeforeTheDeviceNames() throws {
        let device = try Fixture.device("dev.p", outputs: 4)
        let wide = RouteRoleRequirement(direction: .output, channelCount: 2)
        let labels = try Fixture.labels()
        let other = try Fixture.role("rol.other")
        func attempt(_ source: RigRoleCandidates, names: [DeviceID: String]) throws -> RouteChoiceList {
            try RouteChoiceList.make(
                role: Fixture.role("rol.cue"), requirement: wide, candidates: source,
                existingRoutes: [], deviceNames: names, roleLabels: labels
            )
        }
        let breaksBoth = try Fixture.source("rol.other", width: 1, on: [device])
        let foreign = try Fixture.source("rol.other", on: [device])
        let misfit = try Fixture.source(width: 1, on: [device])
        let id = try DeviceID("dev.p")
        for names in [Fixture.names(for: [device]), [:]] {
            #expect(throws: RouteChoiceListRefusal.candidateForOtherRole(other)) {
                try attempt(breaksBoth, names: names)
            }
            #expect(throws: RouteChoiceListRefusal.candidateForOtherRole(other)) {
                try attempt(foreign, names: names)
            }
            #expect(throws: RouteChoiceListRefusal.candidateDoesNotFit(device: id, firstChannel: 0)) {
                try attempt(misfit, names: names)
            }
        }
    }

    @Test func claimantLabelOffendersAreTheSmallestIDByBytesWhateverTheKind() throws {
        let device = try Fixture.device("dev.p", outputs: 4)
        let cue = try Fixture.role("rol.cue")
        let long = String(repeating: "n", count: 129)
        for count in 8...12 {
            let ids = (0..<count).map { "rol.k\($0)" }
            let routes = try ids.enumerated().map { index, role in
                try Fixture.route("rte.k\(index)", role, "dev.p", [0, 1])
            }
            let smallest = try Fixture.role("rol.k0")
            let second = try Fixture.role("rol.k1")
            var labels: [RoleID: String] = [cue: "Cue"]
            #expect(throws: RouteChoiceListRefusal.missingRoleLabel(smallest)) {
                try Fixture.make(on: [device], routes: routes, labels: labels)
            }
            for role in ids { labels[try Fixture.role(role)] = "" }
            #expect(throws: RouteChoiceListRefusal.invalidRoleLabelLength(smallest, bytes: 0)) {
                try Fixture.make(on: [device], routes: routes, labels: labels)
            }
            for role in ids.dropFirst(2) { labels[try Fixture.role(role)] = "Fine" }
            labels[second] = nil
            #expect(throws: RouteChoiceListRefusal.invalidRoleLabelLength(smallest, bytes: 0)) {
                try Fixture.make(on: [device], routes: routes, labels: labels)
            }
            labels[second] = long
            #expect(throws: RouteChoiceListRefusal.invalidRoleLabelLength(smallest, bytes: 0)) {
                try Fixture.make(on: [device], routes: routes, labels: labels)
            }
            labels[smallest] = nil
            #expect(throws: RouteChoiceListRefusal.missingRoleLabel(smallest)) {
                try Fixture.make(on: [device], routes: routes, labels: labels)
            }
            labels[smallest] = "Fine"
            #expect(throws: RouteChoiceListRefusal.invalidRoleLabelLength(second, bytes: 129)) {
                try Fixture.make(on: [device], routes: routes, labels: labels)
            }
            labels[second] = nil
            #expect(throws: RouteChoiceListRefusal.missingRoleLabel(second)) {
                try Fixture.make(on: [device], routes: routes, labels: labels)
            }
        }
    }
}
