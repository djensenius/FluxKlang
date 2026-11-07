//
//  WorkspaceStatusTests+Refusals.swift
//  FluxKlangTests
//
//  What the status projection refuses (#99 W3): every name and count bound with its N and N+1 case, the
//  documented order of refusals, and the rule that a refusal never repairs, trims or changes anything.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WorkspaceStatusTests {
    /// A quiet scenario after `edit`.
    static func edited(_ edit: (inout Scenario) -> Void) -> Scenario {
        var scenario = Scenario()
        edit(&scenario)
        return scenario
    }

    /// An ASCII name of exactly `bytes` UTF-8 bytes.
    static func name(bytes: Int) -> String {
        String(repeating: "n", count: bytes)
    }

    /// Diagnostics counts that are zero except for `severity`.
    static func counts(_ severity: DiagnosticSeverity, _ value: Int) -> WorkspaceStatusDiagnosticCounts {
        switch severity {
        case .error: WorkspaceStatusDiagnosticCounts(errors: value, warnings: 0, infos: 0)
        case .warning: WorkspaceStatusDiagnosticCounts(errors: 0, warnings: value, infos: 0)
        case .info: WorkspaceStatusDiagnosticCounts(errors: 0, warnings: 0, infos: value)
        }
    }

    @Test func hostNameBoundAccepts128BytesAndRefuses129() throws {
        let atBound = Self.edited { $0.hostName = Self.name(bytes: 128) }
        let accepted = try atBound.projection()
        #expect(accepted.segment(.engine).text == "Running (\(Self.name(bytes: 128)))")
        let single = Self.edited { $0.hostName = Self.name(bytes: 1) }
        #expect(try single.projection().segment(.engine).text == "Running (n)")
        let overBound = Self.edited { $0.hostName = Self.name(bytes: 129) }
        Self.expectRefusal(.nameTooLong(.hostName, bytes: 129), overBound)
        let far = Self.edited { $0.hostName = Self.name(bytes: 1_000) }
        Self.expectRefusal(.nameTooLong(.hostName, bytes: 1_000), far)
        let empty = Self.edited { $0.hostName = "" }
        Self.expectRefusal(.emptyName(.hostName), empty)
    }

    @Test func hostNameIsValidatedWhateverTheLifecycleShows() throws {
        let revision = try ContractRevision(3)
        let lifecycles: [EngineLifecycle] = [
            .stopped, .preparing(revision, over: .absent), .running, .degraded([]), .recovering,
            .heldByOther(ProjectID(validated: "prj.other"))
        ]
        for lifecycle in lifecycles {
            let empty = Self.edited {
                $0.lifecycle = lifecycle
                $0.hostName = ""
            }
            Self.expectRefusal(.emptyName(.hostName), empty)
            let long = Self.edited {
                $0.lifecycle = lifecycle
                $0.hostName = Self.name(bytes: 129)
            }
            Self.expectRefusal(.nameTooLong(.hostName, bytes: 129), long)
        }
    }

    @Test func nameBoundCountsUTF8BytesNotCharacters() throws {
        let accepted = [
            String(repeating: "\u{e9}", count: 64), String(repeating: "\u{20ac}", count: 42),
            String(repeating: "\u{1f600}", count: 32), Self.name(bytes: 127) + "n"
        ]
        for name in accepted {
            let scenario = Self.edited { $0.hostName = name }
            let projection = try scenario.projection()
            #expect(projection.segment(.engine).text == "Running (\(name))")
        }
        let refused: [(name: String, bytes: Int)] = [
            (String(repeating: "\u{e9}", count: 65), 130), (String(repeating: "\u{20ac}", count: 43), 129),
            (String(repeating: "\u{1f600}", count: 33), 132), (Self.name(bytes: 127) + "\u{e9}", 129)
        ]
        for row in refused {
            let scenario = Self.edited { $0.hostName = row.name }
            Self.expectRefusal(.nameTooLong(.hostName, bytes: row.bytes), scenario)
        }
    }

    @Test func deviceNameBoundsReportTheRowIndex() throws {
        let atBound = Self.edited {
            $0.devices = [Self.device(Self.name(bytes: 128), .present), Self.device("Pad B", .present)]
        }
        #expect(try atBound.projection().segment(.devices).text == "All present")
        let overBound = Self.edited {
            $0.devices = [Self.device("Pad A", .present), Self.device(Self.name(bytes: 129), .missing)]
        }
        Self.expectRefusal(.nameTooLong(.deviceName(index: 1), bytes: 129), overBound)
        let present = Self.names("Pad", 3).map { Self.device($0, .present) }
        let empty = Self.edited { $0.devices = present + [Self.device("", .stale)] }
        Self.expectRefusal(.emptyName(.deviceName(index: 3)), empty)
    }

    @Test func devicesAreValidatedInRowOrder() {
        let scenario = Self.edited {
            $0.devices = [Self.device(Self.name(bytes: 129), .present), Self.device("", .present)]
        }
        Self.expectRefusal(.nameTooLong(.deviceName(index: 0), bytes: 129), scenario)
    }

    @Test func peerNameBoundsReportTheRowIndex() throws {
        let session = try Self.session(epoch: 1)
        let atBound = Self.edited { $0.peers = [Self.peer(Self.name(bytes: 128), .connected(session))] }
        let accepted = try atBound.projection()
        #expect(accepted.segment(.peers).text == "\(Self.name(bytes: 128)) connected (epoch 1)")
        let overBound = Self.edited {
            $0.peers = [Self.peer("A", .connected(session)), Self.peer(Self.name(bytes: 129), .connected(session))]
        }
        Self.expectRefusal(.nameTooLong(.peerName(index: 1), bytes: 129), overBound)
        let empty = Self.edited {
            $0.peers = [
                Self.peer("A", .connected(session)), Self.peer("B", .connected(session)),
                Self.peer("", .connected(session))
            ]
        }
        Self.expectRefusal(.emptyName(.peerName(index: 2)), empty)
    }

    @Test func deviceRowsBeyondTheLabelCapAreStillValidated() {
        var rows = Self.names("D", 5).map { Self.device($0, .missing) }
        rows.append(Self.device("", .present))
        let empty = Self.edited { $0.devices = rows }
        Self.expectRefusal(.emptyName(.deviceName(index: 5)), empty)
        rows[5] = Self.device(Self.name(bytes: 129), .present)
        let long = Self.edited { $0.devices = rows }
        Self.expectRefusal(.nameTooLong(.deviceName(index: 5), bytes: 129), long)
    }

    @Test func peerRowsBeyondTheSummaryCapAreStillValidated() throws {
        var rows = try Self.syncedPeers(4)
        let hidden = try Self.session(epoch: 9)
        rows.append(Self.peer(Self.name(bytes: 129), .disconnected(hidden)))
        let long = Self.edited { $0.peers = rows }
        Self.expectRefusal(.nameTooLong(.peerName(index: 4), bytes: 129), long)
        rows[4] = Self.peer("Hidden", .disconnected(hidden), stale: -1)
        let stale = Self.edited { $0.peers = rows }
        Self.expectRefusal(.countOutOfRange(.discardedCommands(peerIndex: 4), value: -1), stale)
    }

    @Test func staleCommandCountAccepts0And1000000AndRefusesBeyondWithTheRowIndex() throws {
        let session = try Self.session(epoch: 1)
        for count in [0, 1, 999_999, 1_000_000] {
            let scenario = Self.edited { $0.peers = [Self.peer("P", .connected(session), stale: count)] }
            let projection = try scenario.projection()
            #expect(projection.segment(.peers).text.isEmpty == false, "count \(count)")
        }
        for count in [1_000_001, -1, Int.max, Int.min] {
            let scenario = Self.edited {
                $0.peers = [Self.peer("A", .connected(session)), Self.peer("B", .connected(session), stale: count)]
            }
            Self.expectRefusal(.countOutOfRange(.discardedCommands(peerIndex: 1), value: count), scenario)
        }
    }

    @Test func draftCountAccepts0And1000000AndRefusesBeyond() throws {
        let none = try Self.projection { $0.draftCount = 0 }
        #expect(none.segment(.draft).text == "None awaiting review")
        for count in [1, 999_999, 1_000_000] {
            let projection = try Self.projection { $0.draftCount = count }
            #expect(projection.segment(.draft).text == "\(count) awaiting review")
        }
        for count in [1_000_001, -1, Int.max, Int.min] {
            let scenario = Self.edited { $0.draftCount = count }
            Self.expectRefusal(.countOutOfRange(.draftCount, value: count), scenario)
        }
    }

    @Test func diagnosticCountsAcceptZeroAndOneMillionAndRefuseBeyondForEverySeverity() throws {
        for severity in DiagnosticSeverity.allCases {
            for value in [0, 1, 999_999, 1_000_000] {
                let projection = try Self.projection { $0.diagnostics = Self.counts(severity, value) }
                #expect(projection.diagnostics.total == value, "\(severity) \(value)")
            }
            for value in [1_000_001, -1, Int.max, Int.min] {
                let scenario = Self.edited { $0.diagnostics = Self.counts(severity, value) }
                Self.expectRefusal(.countOutOfRange(.diagnosticCount(severity), value: value), scenario)
            }
        }
    }

    @Test func nominalRateAccepts1And768000AndRefusesZeroAndBeyond() throws {
        for rate in [1, 44_100, 48_000, 768_000] {
            let clock = try Self.clockSegment(nominal: rate, measured: nil)
            #expect(clock.text == "\(WorkspaceStatusFormat.kilohertz(rate)) nominal, actual Unavailable")
        }
        for rate in [0, 768_001, -1, Int.max, Int.min] {
            let scenario = Self.edited {
                $0.clock = WorkspaceStatusClock(nominalHertz: rate, measuredHertz: nil)
            }
            Self.expectRefusal(.nominalRateOutOfRange(rate), scenario)
        }
    }

    @Test func measuredRateAccepts1And768000AndRefusesZeroAndBeyond() throws {
        for rate in [1, 44_100, 48_000, 768_000] {
            let clock = try Self.clockSegment(nominal: 48_000, measured: rate)
            #expect(clock.text == "48 kHz nominal, actual \(WorkspaceStatusFormat.kilohertz(rate))")
        }
        for rate in [0, 768_001, -1, Int.max, Int.min] {
            let scenario = Self.edited {
                $0.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: rate)
            }
            Self.expectRefusal(.measuredRateOutOfRange(rate), scenario)
        }
    }

    @Test func refusalsAreReportedInTheDocumentedOrder() throws {
        let session = try Self.session(epoch: 1)
        var scenario = Scenario()
        scenario.hostName = ""
        scenario.devices = [Self.device("", .present), Self.device(Self.name(bytes: 129), .present)]
        scenario.clock = WorkspaceStatusClock(nominalHertz: 0, measuredHertz: 0)
        scenario.peers = [Self.peer("", .connected(session), stale: -1)]
        scenario.draftCount = -1
        scenario.diagnostics = WorkspaceStatusDiagnosticCounts(errors: -1, warnings: -2, infos: -3)
        Self.expectRefusal(.emptyName(.hostName), scenario)
        scenario.hostName = "Host A"
        Self.expectRefusal(.emptyName(.deviceName(index: 0)), scenario)
        scenario.devices[0] = Self.device("Pad A", .present)
        Self.expectRefusal(.nameTooLong(.deviceName(index: 1), bytes: 129), scenario)
        scenario.devices[1] = Self.device("Pad B", .present)
        Self.expectRefusal(.nominalRateOutOfRange(0), scenario)
        scenario.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: 0)
        Self.expectRefusal(.measuredRateOutOfRange(0), scenario)
        scenario.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: 48_000)
        Self.expectRefusal(.emptyName(.peerName(index: 0)), scenario)
        scenario.peers = [Self.peer("Remote C", .connected(session), stale: -1)]
        Self.expectRefusal(.countOutOfRange(.discardedCommands(peerIndex: 0), value: -1), scenario)
        scenario.peers = [Self.peer("Remote C", .connected(session))]
        Self.expectRefusal(.countOutOfRange(.draftCount, value: -1), scenario)
        scenario.draftCount = 0
        Self.expectRefusal(.countOutOfRange(.diagnosticCount(.error), value: -1), scenario)
        scenario.diagnostics = WorkspaceStatusDiagnosticCounts(errors: 0, warnings: -2, infos: -3)
        Self.expectRefusal(.countOutOfRange(.diagnosticCount(.warning), value: -2), scenario)
        scenario.diagnostics = WorkspaceStatusDiagnosticCounts(errors: 0, warnings: 0, infos: -3)
        Self.expectRefusal(.countOutOfRange(.diagnosticCount(.info), value: -3), scenario)
        scenario.diagnostics = WorkspaceStatusDiagnosticCounts(errors: 0, warnings: 0, infos: 0)
        let projection = try scenario.projection()
        #expect(projection.segment(.peers).text == "Remote C connected (epoch 1)")
    }

    @Test func peerRowsAreValidatedRowByRowNameThenCount() throws {
        let session = try Self.session(epoch: 1)
        let firstCountBad = Self.edited {
            $0.peers = [Self.peer("A", .connected(session), stale: -5), Self.peer("", .connected(session))]
        }
        Self.expectRefusal(.countOutOfRange(.discardedCommands(peerIndex: 0), value: -5), firstCountBad)
        let sameRowBothBad = Self.edited { $0.peers = [Self.peer("", .connected(session), stale: -5)] }
        Self.expectRefusal(.emptyName(.peerName(index: 0)), sameRowBothBad)
    }

    @Test func localNetworkOffStillValidatesPeerRows() throws {
        let session = try Self.session(epoch: 1)
        let long = Self.edited {
            $0.permissions = Self.permissions(localNetwork: .denied)
            $0.peers = [Self.peer(Self.name(bytes: 129), .connected(session))]
        }
        Self.expectRefusal(.nameTooLong(.peerName(index: 0), bytes: 129), long)
        let stale = Self.edited {
            $0.permissions = Self.permissions(localNetwork: .restricted)
            $0.peers = [Self.peer("A", .connected(session), stale: -1)]
        }
        Self.expectRefusal(.countOutOfRange(.discardedCommands(peerIndex: 0), value: -1), stale)
    }

    @Test func aRefusalIsDeterministicAndLeavesTheInputsUnchanged() throws {
        let scenario = Self.edited {
            $0.devices = [Self.device("Pad A", .missing)]
            $0.draftCount = 1_000_001
        }
        let before = scenario.inputs
        for _ in 0..<3 {
            Self.expectRefusal(.countOutOfRange(.draftCount, value: 1_000_001), scenario)
        }
        #expect(scenario.inputs == before)
        let repaired = Self.edited {
            $0.devices = [Self.device("Pad A", .missing)]
            $0.draftCount = 1_000_000
        }
        let projection = try repaired.projection()
        #expect(projection.segment(.draft).text == "1000000 awaiting review")
        #expect(projection.segment(.devices).lostItems == ["Pad A"])
    }

    @Test func namesAreNeverTrimmedSoOnlyAZeroLengthNameIsEmpty() throws {
        let session = try Self.session(epoch: 1)
        let scenario = Self.edited {
            $0.hostName = " "
            $0.devices = [Self.device(" ", .missing)]
            $0.peers = [Self.peer("\n", .disconnected(session))]
        }
        let projection = try scenario.projection()
        #expect(projection.segment(.engine).text == "Running ( )")
        #expect(projection.segment(.devices).label == "Devices:   missing")
        #expect(projection.segment(.devices).lostItems == [" "])
        #expect(projection.segment(.peers).text == "\n disconnected")
        #expect(projection.segment(.peers).lostItems == ["\n"])
    }

    @Test func diagnosticsAreCarriedWithTheirCountsAndFoldIntoNoSegment() throws {
        let baseline = try Self.projection()
        let counted = try Self.projection {
            $0.diagnostics = WorkspaceStatusDiagnosticCounts(errors: 2, warnings: 3, infos: 4)
        }
        #expect(counted.diagnostics.errors == 2)
        #expect(counted.diagnostics.warnings == 3)
        #expect(counted.diagnostics.infos == 4)
        #expect(counted.diagnostics.total == 9)
        #expect(counted.segments == baseline.segments)
        #expect(counted != baseline)
        let million = 1_000_000
        let most = try Self.projection {
            $0.diagnostics = WorkspaceStatusDiagnosticCounts(errors: million, warnings: million, infos: million)
        }
        #expect(most.diagnostics.total == 3_000_000)
        #expect(most.segments == baseline.segments)
    }

    @Test func diagnosticCountsAreReadBySeverityInTheOrderErrorWarningInfo() {
        let counts = WorkspaceStatusDiagnosticCounts(errors: 1, warnings: 2, infos: 3)
        #expect(DiagnosticSeverity.allCases == [.error, .warning, .info])
        #expect(DiagnosticSeverity.allCases.map { counts.count(of: $0) } == [1, 2, 3])
    }
}
