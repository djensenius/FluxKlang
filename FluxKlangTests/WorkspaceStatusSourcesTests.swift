//
//  WorkspaceStatusSourcesTests.swift
//  FluxKlangTests
//
//  The status strip's sources (#99 WSS1): diagnostic counts, the device row order and the device row refusals.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct WorkspaceStatusSourcesTests {
    private func record(_ severity: DiagnosticSeverity, _ number: Int = 0) throws -> NeutralDiagnosticRecord {
        NeutralDiagnosticRecord(id: try DiagnosticID("diag.\(number)"), severity: severity, summary: "text")
    }

    private func counts(_ errors: Int, _ warnings: Int, _ infos: Int) -> WorkspaceStatusDiagnosticCounts {
        WorkspaceStatusDiagnosticCounts(errors: errors, warnings: warnings, infos: infos)
    }

    private func descriptor(_ raw: String, _ presence: DevicePresence = .present) throws -> DeviceDescriptor {
        try DeviceDescriptor(
            id: DeviceID(raw), kind: .audioInterface, layout: nil, binding: .reported,
            identity: DeviceIdentity(.init(uid: "uid-\(raw)", evidence: [.deviceUID])), presence: presence
        )
    }

    /// The names table for `pairs`, keyed by device id.
    private func table(_ pairs: KeyValuePairs<String, String>) throws -> [DeviceID: String] {
        var result: [DeviceID: String] = [:]
        for (raw, name) in pairs { result[try DeviceID(raw)] = name }
        return result
    }

    private func names(_ rows: [WorkspaceStatusDevice]) -> [String] {
        rows.map(\.name)
    }

    // MARK: - Counts

    @Test
    func countsOfNoRecordsAreAllZero() {
        let result = WorkspaceStatusSources.diagnosticCounts(of: [])
        #expect(result == counts(0, 0, 0))
    }

    @Test
    func countsOfOneRecordPerSeverityAreOneEach() throws {
        let records = [try record(.error, 1), try record(.warning, 2), try record(.info, 3)]
        let result = WorkspaceStatusSources.diagnosticCounts(of: records)
        #expect(result == counts(1, 1, 1))
    }

    @Test
    func countsOfMixedRecordsFollowEachRecordsSeverity() throws {
        let records = [
            try record(.warning, 1), try record(.error, 2), try record(.info, 3),
            try record(.error, 4), try record(.warning, 5), try record(.error, 6)
        ]
        let result = WorkspaceStatusSources.diagnosticCounts(of: records)
        #expect(result == counts(3, 2, 1))
    }

    @Test
    func countsOfASingleSeverityFillOnlyThatCount() throws {
        let errorsOnly = WorkspaceStatusSources.diagnosticCounts(of: [try record(.error, 1), try record(.error, 2)])
        let warningsOnly = WorkspaceStatusSources.diagnosticCounts(of: [try record(.warning, 1)])
        let infosOnly = WorkspaceStatusSources.diagnosticCounts(
            of: [try record(.info, 1), try record(.info, 2), try record(.info, 3)]
        )
        #expect(errorsOnly == counts(2, 0, 0))
        #expect(warningsOnly == counts(0, 1, 0))
        #expect(infosOnly == counts(0, 0, 3))
    }

    @Test
    func countsKeepRecordsThatShareAnIdSeparate() throws {
        let records = [try record(.error, 7), try record(.error, 7), try record(.warning, 7)]
        let result = WorkspaceStatusSources.diagnosticCounts(of: records)
        #expect(result == counts(2, 1, 0))
    }

    @Test
    func countsDoNotChangeWhenTheRecordsAreReversed() throws {
        let records = [
            try record(.info, 1), try record(.error, 2), try record(.error, 3),
            try record(.warning, 4), try record(.info, 5)
        ]
        let forward = WorkspaceStatusSources.diagnosticCounts(of: records)
        let backward = WorkspaceStatusSources.diagnosticCounts(of: records.reversed())
        #expect(forward == counts(2, 1, 2))
        #expect(backward == forward)
    }

    // MARK: - Row order

    @Test
    func rowsOfNoDevicesAreEmptyWithAnEmptyTable() throws {
        let rows = try WorkspaceStatusSources.deviceRows([], names: [:])
        #expect(rows.isEmpty)
    }

    @Test
    func aSingleDeviceGivesItsOneRow() throws {
        let devices = [try descriptor("d.1", .stale)]
        let rows = try WorkspaceStatusSources.deviceRows(devices, names: try table(["d.1": "Solo"]))
        let expected = [WorkspaceStatusDevice(name: "Solo", presence: .stale)]
        #expect(rows == expected)
    }

    @Test
    func rowsFollowTheHandTypedNameByteOrder() throws {
        let devices = [
            try descriptor("d.1"), try descriptor("d.2"), try descriptor("d.3"), try descriptor("d.4"),
            try descriptor("d.5")
        ]
        let rows = try WorkspaceStatusSources.deviceRows(
            devices, names: try table(["d.1": "Zed", "d.2": "alpha", "d.3": "Pad B", "d.4": "Pad A", "d.5": "Pad"])
        )
        let expected = ["Pad", "Pad A", "Pad B", "Zed", "alpha"]
        #expect(names(rows) == expected)
    }

    @Test
    func rowsCarryEachDescriptorsPresenceUnchanged() throws {
        let devices = [try descriptor("d.1", .missing), try descriptor("d.2", .present), try descriptor("d.3", .stale)]
        let rows = try WorkspaceStatusSources.deviceRows(
            devices, names: try table(["d.1": "One", "d.2": "Two", "d.3": "Three"])
        )
        let expected = [
            WorkspaceStatusDevice(name: "One", presence: .missing),
            WorkspaceStatusDevice(name: "Three", presence: .stale),
            WorkspaceStatusDevice(name: "Two", presence: .present)
        ]
        #expect(rows == expected)
    }

    @Test
    func precomposedAndDecomposedNamesStayTwoRowsOrderedByTheirBytes() throws {
        let devices = [try descriptor("d.1", .missing), try descriptor("d.2", .stale)]
        let rows = try WorkspaceStatusSources.deviceRows(
            devices, names: try table(["d.1": "caf\u{E9}", "d.2": "cafe\u{301}"])
        )
        let presences = rows.map(\.presence)
        let expectedPresences: [DevicePresence] = [.stale, .missing]
        #expect(presences == expectedPresences)
        try #require(rows.count == 2)
        let first = try #require(rows.first)
        let last = try #require(rows.last)
        let expectedFirst: [UInt8] = [0x63, 0x61, 0x66, 0x65, 0xCC, 0x81]
        let expectedLast: [UInt8] = [0x63, 0x61, 0x66, 0xC3, 0xA9]
        #expect(Array(first.name.utf8) == expectedFirst)
        #expect(Array(last.name.utf8) == expectedLast)
    }

    @Test
    func aNameThatIsAByteprefixOfAnotherComesFirstWhateverTheInputOrder() throws {
        let longFirst = [try descriptor("d.1"), try descriptor("d.2")]
        let all = try table(["d.1": "ab", "d.2": "a"])
        let forward = try WorkspaceStatusSources.deviceRows(longFirst, names: all)
        let backward = try WorkspaceStatusSources.deviceRows(longFirst.reversed(), names: all)
        let expected = ["a", "ab"]
        #expect(names(forward) == expected)
        #expect(names(backward) == expected)
    }

    @Test
    func equalNamesKeepTwoRowsOrderedByDeviceIdWhateverTheInputOrder() throws {
        let all = try table(["d.a": "Same", "d.b": "Same"])
        let forward = try WorkspaceStatusSources.deviceRows(
            [try descriptor("d.a", .missing), try descriptor("d.b", .stale)], names: all
        )
        let backward = try WorkspaceStatusSources.deviceRows(
            [try descriptor("d.b", .stale), try descriptor("d.a", .missing)], names: all
        )
        let expected = [
            WorkspaceStatusDevice(name: "Same", presence: .missing),
            WorkspaceStatusDevice(name: "Same", presence: .stale)
        ]
        #expect(forward == expected)
        #expect(backward == expected)
    }

    @Test
    func namesAreNotCaseFoldedSoCapitalAComesBeforeSmallA() throws {
        let devices = [try descriptor("d.1", .stale), try descriptor("d.2", .missing)]
        let rows = try WorkspaceStatusSources.deviceRows(devices, names: try table(["d.1": "a", "d.2": "A"]))
        let expected = [
            WorkspaceStatusDevice(name: "A", presence: .missing),
            WorkspaceStatusDevice(name: "a", presence: .stale)
        ]
        #expect(rows == expected)
    }

    @Test
    func equalNamesWithIdsHyphenDotUnderscoreAreOrderedByIdBytes() throws {
        let devices = [
            try descriptor("d_1", .stale), try descriptor("d.1", .missing), try descriptor("d-1", .present)
        ]
        let rows = try WorkspaceStatusSources.deviceRows(
            devices, names: try table(["d_1": "Same", "d.1": "Same", "d-1": "Same"])
        )
        let presences = rows.map(\.presence)
        let expected: [DevicePresence] = [.present, .missing, .stale]
        #expect(presences == expected)
    }

    @Test
    func theRowsAreTheSameForEveryRotationAndTheReversalOfTheInput() throws {
        let raws = ["d.1", "d.2", "d.3", "d.4", "d.5", "d.6", "d.7", "d.8"]
        let labels = ["Zed", "alpha", "Pad", "Pad", "Pad A", "caf\u{E9}", "cafe\u{301}", "Pad"]
        let presences: [DevicePresence] = [.present, .missing, .stale, .present, .missing, .stale, .present, .missing]
        var devices: [DeviceDescriptor] = []
        var pairs: [DeviceID: String] = [:]
        for index in raws.indices {
            devices.append(try descriptor(raws[index], presences[index]))
            pairs[try DeviceID(raws[index])] = labels[index]
        }
        let baseline = try WorkspaceStatusSources.deviceRows(devices, names: pairs)
        #expect(baseline.count == 8)
        for shift in 1..<devices.count {
            let rotated = Array(devices[shift...] + devices[..<shift])
            let rows = try WorkspaceStatusSources.deviceRows(rotated, names: pairs)
            #expect(rows == baseline)
        }
        let reversedRows = try WorkspaceStatusSources.deviceRows(devices.reversed(), names: pairs)
        #expect(reversedRows == baseline)
    }

    // MARK: - Names pass through

    @Test
    func emptyWhitespaceAndOverlongNamesPassThroughByteForByte() throws {
        let long = String(repeating: "x", count: 129)
        let devices = [try descriptor("d.1"), try descriptor("d.2"), try descriptor("d.3")]
        let rows = try WorkspaceStatusSources.deviceRows(
            devices, names: try table(["d.1": "", "d.2": "  pad  ", "d.3": long])
        )
        let expected = ["", "  pad  ", long]
        #expect(names(rows) == expected)
    }

    @Test
    func extraEntriesInTheNamesTableAreIgnored() throws {
        let rows = try WorkspaceStatusSources.deviceRows(
            [try descriptor("d.1")], names: try table(["d.1": "Mine", "d.2": "Other", "d.3": "Another"])
        )
        let expected = ["Mine"]
        #expect(names(rows) == expected)
    }

    // MARK: - Refusals

    @Test
    func moreThanTheInventoryLimitOfDevicesIsRefusedWithTheCount() throws {
        var devices: [DeviceDescriptor] = []
        for index in 0...1_024 { devices.append(try descriptor("dev.\(index)")) }
        #expect(throws: WorkspaceStatusSourceRefusal.tooManyDevices(count: 1_025, maximum: 1_024)) {
            try WorkspaceStatusSources.deviceRows(devices, names: [:])
        }
    }

    @Test
    func aRepeatedDeviceIdIsRefusedAndNamed() throws {
        let devices = [try descriptor("d.1"), try descriptor("d.2"), try descriptor("d.2")]
        let all = try table(["d.1": "One", "d.2": "Two"])
        #expect(throws: WorkspaceStatusSourceRefusal.duplicateDevice(try DeviceID("d.2"))) {
            try WorkspaceStatusSources.deviceRows(devices, names: all)
        }
    }

    @Test
    func twoRepeatedDeviceIdsNameTheSmallestWhateverTheInputOrder() throws {
        let all = try table(["d.3": "Three", "d.9": "Nine"])
        let largeFirst = [try descriptor("d.9"), try descriptor("d.9"), try descriptor("d.3"), try descriptor("d.3")]
        let smallFirst = [try descriptor("d.3"), try descriptor("d.9"), try descriptor("d.3"), try descriptor("d.9")]
        let expected = WorkspaceStatusSourceRefusal.duplicateDevice(try DeviceID("d.3"))
        #expect(throws: expected) { try WorkspaceStatusSources.deviceRows(largeFirst, names: all) }
        #expect(throws: expected) { try WorkspaceStatusSources.deviceRows(smallFirst, names: all) }
    }

    @Test
    func aDeviceWithoutANameIsRefusedAndNamed() throws {
        let devices = [try descriptor("d.1"), try descriptor("d.2")]
        let all = try table(["d.1": "One"])
        #expect(throws: WorkspaceStatusSourceRefusal.missingName(try DeviceID("d.2"))) {
            try WorkspaceStatusSources.deviceRows(devices, names: all)
        }
    }

    @Test
    func twoDevicesWithoutANameNameTheSmallestWhateverTheInputOrder() throws {
        let all = try table(["d.1": "One"])
        let largeFirst = [try descriptor("d.8"), try descriptor("d.4"), try descriptor("d.1")]
        let smallFirst = [try descriptor("d.1"), try descriptor("d.4"), try descriptor("d.8")]
        let expected = WorkspaceStatusSourceRefusal.missingName(try DeviceID("d.4"))
        #expect(throws: expected) { try WorkspaceStatusSources.deviceRows(largeFirst, names: all) }
        #expect(throws: expected) { try WorkspaceStatusSources.deviceRows(smallFirst, names: all) }
    }

    @Test
    func aRepeatedIdThatIsNamedStillCountsAsRepeatedWhenItsNameIsEmpty() throws {
        let devices = [try descriptor("d.1"), try descriptor("d.1")]
        #expect(throws: WorkspaceStatusSourceRefusal.duplicateDevice(try DeviceID("d.1"))) {
            try WorkspaceStatusSources.deviceRows(devices, names: try table(["d.1": ""]))
        }
    }

    // MARK: - Refusal order, one fixture holding both defects per adjacent pair

    @Test
    func theCountIsRefusedBeforeARepeatedIdInTheSameInput() throws {
        var devices: [DeviceDescriptor] = []
        for index in 0..<1_024 { devices.append(try descriptor("dev.\(index)")) }
        devices.append(try descriptor("dev.0"))
        #expect(throws: WorkspaceStatusSourceRefusal.tooManyDevices(count: 1_025, maximum: 1_024)) {
            try WorkspaceStatusSources.deviceRows(devices, names: [:])
        }
    }

    @Test
    func aRepeatedIdIsRefusedBeforeADeviceWithoutANameInTheSameInput() throws {
        let devices = [try descriptor("d.1"), try descriptor("d.5"), try descriptor("d.5")]
        let all = try table(["d.5": "Five"])
        #expect(throws: WorkspaceStatusSourceRefusal.duplicateDevice(try DeviceID("d.5"))) {
            try WorkspaceStatusSources.deviceRows(devices, names: all)
        }
    }
}
