//
//  WorkspaceStatusSourcesTests+Limits.swift
//  FluxKlangTests
//
//  The status strip's sources at their limits, through the projection, and the source scan (#99 WSS1).
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WorkspaceStatusSourcesTests {
    private func padded(_ number: Int) -> String {
        let text = String(number)
        return String(repeating: "0", count: 4 - text.count) + text
    }

    private func device(_ raw: String, _ presence: DevicePresence = .present) throws -> DeviceDescriptor {
        try DeviceDescriptor(
            id: DeviceID(raw), kind: .audioInterface, layout: nil, binding: .reported,
            identity: DeviceIdentity(.init(uid: "uid-\(raw)", evidence: [.deviceUID])), presence: presence
        )
    }

    private func rows(
        _ entries: KeyValuePairs<String, String>, _ presence: DevicePresence
    ) throws -> [WorkspaceStatusDevice] {
        var devices: [DeviceDescriptor] = []
        var all: [DeviceID: String] = [:]
        for (raw, name) in entries {
            devices.append(try device(raw, presence))
            all[try DeviceID(raw)] = name
        }
        return try WorkspaceStatusSources.deviceRows(devices, names: all)
    }

    // MARK: - Limits

    @Test
    func theInventoryLimitOfDevicesIsAcceptedAndTheFirstAndLastRowsAreTheHandTypedOnes() throws {
        let pattern: [DevicePresence] = [.present, .missing, .stale, .missing, .present]
        var devices: [DeviceDescriptor] = []
        var all: [DeviceID: String] = [:]
        for index in 0..<1_024 {
            let raw = "dev.\(padded(index))"
            devices.append(try device(raw, pattern[index % 5]))
            all[try DeviceID(raw)] = "n\(padded(1_023 - index))"
        }
        let result = try WorkspaceStatusSources.deviceRows(devices, names: all)
        try #require(result.count == 1_024)
        let first = try #require(result.first)
        let second = try #require(result.dropFirst().first)
        let last = try #require(result.last)
        #expect(first == WorkspaceStatusDevice(name: "n0000", presence: .missing))
        #expect(second == WorkspaceStatusDevice(name: "n0001", presence: .stale))
        #expect(last == WorkspaceStatusDevice(name: "n1023", presence: .present))
    }

    @Test
    func oneDeviceFewerThanTheInventoryLimitIsAccepted() throws {
        var devices: [DeviceDescriptor] = []
        var all: [DeviceID: String] = [:]
        for index in 0..<1_023 {
            let raw = "dev.\(padded(index))"
            devices.append(try device(raw))
            all[try DeviceID(raw)] = "n\(padded(index))"
        }
        let result = try WorkspaceStatusSources.deviceRows(devices, names: all)
        #expect(result.count == 1_023)
    }

    @Test
    func oneDeviceMoreThanTheInventoryLimitIsRefusedWithBothNumbers() throws {
        var devices: [DeviceDescriptor] = []
        var all: [DeviceID: String] = [:]
        for index in 0..<1_025 {
            let raw = "dev.\(padded(index))"
            devices.append(try device(raw))
            all[try DeviceID(raw)] = "n\(index)"
        }
        #expect(throws: WorkspaceStatusSourceRefusal.tooManyDevices(count: 1_025, maximum: 1_024)) {
            try WorkspaceStatusSources.deviceRows(devices, names: all)
        }
    }

    @Test
    func aNamesTableOfFiveThousandEntriesStillGivesOneRowPerDevice() throws {
        var all: [DeviceID: String] = [:]
        for index in 0..<5_000 { all[try DeviceID("x.\(padded(index))")] = "name \(index)" }
        let devices = [try device("x.0003"), try device("x.4999"), try device("x.0000")]
        let result = try WorkspaceStatusSources.deviceRows(devices, names: all)
        #expect(result.count == 3)
        let expected = ["name 0", "name 3", "name 4999"]
        #expect(result.map(\.name) == expected)
    }

    // MARK: - Through the projection

    @Test
    func rowOrderIsTheOrderTheDevicesSegmentListsItsMissingNames() throws {
        let sorted = try rows(["d.1": "Zed", "d.2": "alpha", "d.3": "Mid"], .missing)
        let projection = try WorkspaceStatusTests.projection { $0.devices = sorted }
        let expected = ["Mid", "Zed", "alpha"]
        #expect(projection.segment(.devices).lostItems == expected)
    }

    @Test
    func anOverlongNameIsRefusedByTheProjectionAtItsSortedRowIndex() throws {
        let long = String(repeating: "B", count: 129)
        let sorted = try rows(["d.1": "Alpha", "d.2": long, "d.3": "Zed"], .present)
        let expected = WorkspaceStatusRefusal.nameTooLong(.deviceName(index: 1), bytes: 129)
        #expect(throws: expected) { try WorkspaceStatusTests.projection { $0.devices = sorted } }
    }

    @Test
    func anEmptyNameSortsFirstAndIsRefusedByTheProjectionAtRowZero() throws {
        let sorted = try rows(["d.1": "Alpha", "d.2": ""], .present)
        let expected = WorkspaceStatusRefusal.emptyName(.deviceName(index: 0))
        #expect(throws: expected) { try WorkspaceStatusTests.projection { $0.devices = sorted } }
    }

    @Test
    func aNameOfOneHundredTwentyEightBytesIsAcceptedByTheProjection() throws {
        let edge = String(repeating: "b", count: 128)
        let sorted = try rows(["d.1": edge], .stale)
        let projection = try WorkspaceStatusTests.projection { $0.devices = sorted }
        #expect(projection.segment(.devices).lostItems.isEmpty)
    }

    @Test
    func countsOfNineRecordsReachTheProjectionAsATotalOfNine() throws {
        var records: [NeutralDiagnosticRecord] = []
        for index in 0..<9 {
            let severity: DiagnosticSeverity
            switch index {
            case 0..<2: severity = .error
            case 2..<5: severity = .warning
            case _: severity = .info
            }
            records.append(NeutralDiagnosticRecord(
                id: try DiagnosticID("diag.\(index)"), severity: severity, summary: "text"
            ))
        }
        let result = WorkspaceStatusSources.diagnosticCounts(of: records)
        let projection = try WorkspaceStatusTests.projection { $0.diagnostics = result }
        #expect(projection.diagnostics.errors == 2)
        #expect(projection.diagnostics.warnings == 3)
        #expect(projection.diagnostics.infos == 4)
        #expect(projection.diagnostics.total == 9)
    }

    // MARK: - Repeatable

    @Test
    func twoCallsOnTheSameInputGiveEqualRowsAndEqualCounts() throws {
        let devices = [try device("d.1", .missing), try device("d.2", .stale)]
        let all: [DeviceID: String] = [try DeviceID("d.1"): "Two", try DeviceID("d.2"): "One"]
        let first = try WorkspaceStatusSources.deviceRows(devices, names: all)
        let second = try WorkspaceStatusSources.deviceRows(devices, names: all)
        #expect(first == second)
        let expected = ["One", "Two"]
        #expect(first.map(\.name) == expected)
        let records = [NeutralDiagnosticRecord(id: try DiagnosticID("diag.1"), severity: .info, summary: "text")]
        let once = WorkspaceStatusSources.diagnosticCounts(of: records)
        let again = WorkspaceStatusSources.diagnosticCounts(of: records)
        #expect(once == again)
    }

    // MARK: - Source scan

    private static let sourceNames = [
        "WorkspaceStatusSources.swift", "WorkspaceStatusSources+DeviceRows.swift", "WorkspaceStatusSourceRefusal.swift"
    ]

    /// The production files of the sources, read from the checkout or from the package mirror; empty when absent.
    fileprivate static func sourcesText() -> [String] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Shared/Views/Workspace/Shell/Status/Sources/"
        let roots = [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var directories: [URL] = []
        for root in roots {
            directories.append(root.appendingPathComponent(relative))
            directories.append(root.appendingPathComponent("Sources/FluxKlang/" + relative))
        }
        for directory in directories {
            let texts = sourceNames.compactMap {
                try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
            }
            if texts.count == sourceNames.count { return texts }
        }
        return []
    }

    @Test(.enabled(if: !WorkspaceStatusSourcesTests.sourcesText().isEmpty))
    func theSourcesCodeNamesNoQueueFloatingPointSortShortcutOrScanOfTheNamesTable() {
        let texts = Self.sourcesText()
        #expect(texts.count == 3)
        let banned = [
            "Ta" + "sk", "Cl" + "ock", "defa" + "ult:", "Date", "Double", "Float", "Codable", "FileManager",
            "UserDefaults", "try!", "static var", "mutating", ".rawValue <", ".name <", "localizedStandardCompare",
            ".sorted()", ".sort(", "lowercased", "trimmingCharacters", ".contains(", ".firstIndex", ".first(where",
            ".filter(", "Set<DeviceID>(", "insert(", "removeFirst"
        ]
        for text in texts {
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let joined = code.joined(separator: "\n")
            for token in banned { #expect(!joined.contains(token), "\(token)") }
        }
    }
}
