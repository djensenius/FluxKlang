//
//  WorkspaceStatusTests+Devices.swift
//  FluxKlangTests
//
//  The Devices segment of the status strip (#99 W3): rows in input order, the four-row summary bound with
//  an exact "and N more", lost items, and the Microphone and Bluetooth MIDI permission effects.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WorkspaceStatusTests {
    static func devicesSegment(
        _ rows: [WorkspaceStatusDevice], permissions: WorkspaceStatusPermissions = Self.permissions()
    ) throws -> WorkspaceStatusSegment {
        try segment(.devices) {
            $0.devices = rows
            $0.permissions = permissions
        }
    }

    @Test func noDevicesSaysNoDevices() throws {
        let none = try Self.devicesSegment([])
        Self.expectSegment(none, text: "No devices", label: "Devices: No devices", severity: .normal)
    }

    @Test func presentDevicesSayAllPresent() throws {
        let present = try Self.devicesSegment([Self.device("Pad A", .present), Self.device("Pad B", .present)])
        Self.expectSegment(present, text: "All present", label: "Devices: All present", severity: .normal)
    }

    @Test func missingAndStaleRowsAreCountedAndNamedInInputOrder() throws {
        let rows = [
            Self.device("Interface B", .missing), Self.device("Controller A", .stale),
            Self.device("Mixer C", .present), Self.device("Pad D", .missing)
        ]
        let devices = try Self.devicesSegment(rows)
        Self.expectSegment(
            devices, text: "2 missing, 1 stale",
            label: "Devices: Interface B missing, Controller A stale, Pad D missing", severity: .error,
            lostItems: ["Interface B", "Pad D"]
        )
    }

    @Test func staleOnlyIsAttentionAndMissingIsAnErrorWithLostItems() throws {
        let oneStale = try Self.devicesSegment([Self.device("Controller A", .stale)])
        Self.expectSegment(
            oneStale, text: "1 stale", label: "Devices: Controller A stale", severity: .attention
        )
        let twoStale = try Self.devicesSegment([Self.device("Pad A", .stale), Self.device("Pad B", .stale)])
        Self.expectSegment(
            twoStale, text: "2 stale", label: "Devices: Pad A stale, Pad B stale", severity: .attention
        )
        let oneMissing = try Self.devicesSegment([Self.device("Interface B", .missing)])
        Self.expectSegment(
            oneMissing, text: "1 missing", label: "Devices: Interface B missing", severity: .error,
            lostItems: ["Interface B"]
        )
        #expect(oneMissing.glyphName == "exclamationmark.octagon")
        #expect(twoStale.glyphName == "exclamationmark.triangle")
    }

    @Test func deviceLabelListsFourProblemsThenAndNMore() throws {
        let four = try Self.devicesSegment(Self.names("D", 4).map { Self.device($0, .missing) })
        Self.expectSegment(
            four, text: "4 missing", label: "Devices: D1 missing, D2 missing, D3 missing, D4 missing",
            severity: .error, lostItems: ["D1", "D2", "D3", "D4"]
        )
        let five = try Self.devicesSegment(Self.names("D", 5).map { Self.device($0, .missing) })
        #expect(five.text == "5 missing")
        #expect(five.label == "Devices: D1 missing, D2 missing, D3 missing, D4 missing, and 1 more, 1 missing")
        let six = try Self.devicesSegment(Self.names("D", 6).map { Self.device($0, .missing) })
        #expect(six.text == "6 missing")
        #expect(six.label == "Devices: D1 missing, D2 missing, D3 missing, D4 missing, and 2 more, 2 missing")
        let staleSix = try Self.devicesSegment(Self.names("S", 6).map { Self.device($0, .stale) })
        #expect(staleSix.text == "6 stale")
        #expect(staleSix.label == "Devices: S1 stale, S2 stale, S3 stale, S4 stale, and 2 more")
    }

    @Test func aHiddenMissingDeviceAddsItsCountToTheLabel() throws {
        let listed = "Devices: D1 missing, D2 missing, D3 missing, D4 missing"
        let missing = Self.names("D", 5).map { Self.device($0, .missing) }
        let five = try Self.devicesSegment(missing)
        #expect(five.label == "\(listed), and 1 more, 1 missing")
        #expect(five.text == "5 missing")
        let twenty = try Self.devicesSegment(Self.names("D", 20).map { Self.device($0, .missing) })
        #expect(twenty.label == "\(listed), and 16 more, 16 missing")
        let stale = Self.names("S", 4).map { Self.device($0, .stale) }
        let mixed = try Self.devicesSegment(stale + [Self.device("Late", .stale), Self.device("Gone", .missing)])
        Self.expectSegment(
            mixed, text: "1 missing, 5 stale",
            label: "Devices: S1 stale, S2 stale, S3 stale, S4 stale, and 2 more, 1 missing", severity: .error,
            lostItems: ["Gone"]
        )
        let micOff = try Self.devicesSegment(missing, permissions: Self.permissions(microphone: .denied))
        #expect(micOff.label == "\(listed), and 1 more, 1 missing, Microphone access is off")
        #expect(micOff.text == "5 missing, Microphone off")
    }

    @Test func aHiddenStaleDeviceAddsNoSuffix() throws {
        let listed = "Devices: D1 missing, D2 missing, D3 missing, D4 missing"
        let missing = Self.names("D", 4).map { Self.device($0, .missing) }
        let late = Self.device("Late", .stale)
        let later = Self.device("Later", .stale)
        let oneStale = try Self.devicesSegment(missing + [late])
        #expect(oneStale.label == "\(listed), and 1 more")
        #expect(oneStale.severity == .error)
        #expect(oneStale.lostItems == ["D1", "D2", "D3", "D4"])
        let twoStale = try Self.devicesSegment(missing + [late, later])
        #expect(twoStale.label == "\(listed), and 2 more")
        let exactlyFour = try Self.devicesSegment(missing)
        #expect(exactlyFour.label == listed)
    }

    @Test func presentRowsDoNotCountTowardsTheDeviceCap() throws {
        let present = Self.names("P", 3).map { Self.device($0, .present) }
        let missing = Self.names("M", 5).map { Self.device($0, .missing) }
        let devices = try Self.devicesSegment(present + missing)
        #expect(devices.text == "5 missing")
        #expect(devices.label == "Devices: M1 missing, M2 missing, M3 missing, M4 missing, and 1 more, 1 missing")
        #expect(devices.lostItems == ["M1", "M2", "M3", "M4", "M5"])
    }

    @Test func lostItemsListEveryMissingDeviceBeyondTheCapAndNoStaleOne() throws {
        let missing = Self.names("D", 6).map { Self.device($0, .missing) }
        let devices = try Self.devicesSegment(missing + [Self.device("Late", .stale)])
        #expect(devices.lostItems == ["D1", "D2", "D3", "D4", "D5", "D6"])
        #expect(devices.text == "6 missing, 1 stale")
    }

    @Test func microphoneStatusEffectsOverAllEightStates() throws {
        for status in Self.allPermissionStatuses {
            let devices = try Self.devicesSegment([], permissions: Self.permissions(microphone: status))
            if Self.confirmedOff.contains(status) {
                Self.expectSegment(
                    devices, text: "Microphone off", label: "Devices: Microphone access is off",
                    severity: .attention
                )
            } else {
                Self.expectSegment(devices, text: "No devices", label: "Devices: No devices", severity: .normal)
            }
        }
    }

    @Test func bluetoothMIDIStatusEffectsOverAllEightStates() throws {
        for status in Self.allPermissionStatuses {
            let devices = try Self.devicesSegment([], permissions: Self.permissions(bluetoothMIDI: status))
            if Self.confirmedOff.contains(status) {
                Self.expectSegment(
                    devices, text: "Bluetooth MIDI off", label: "Devices: Bluetooth MIDI access is off",
                    severity: .attention
                )
            } else {
                Self.expectSegment(devices, text: "No devices", label: "Devices: No devices", severity: .normal)
            }
        }
    }

    @Test func blockedInputsFollowTheRowCountsInAFixedOrder() throws {
        let rows = [Self.device("Pad A", .missing), Self.device("Pad B", .stale)]
        let bothOff = Self.permissions(microphone: .denied, bluetoothMIDI: .restricted)
        let both = try Self.devicesSegment(rows, permissions: bothOff)
        Self.expectSegment(
            both, text: "1 missing, 1 stale, Microphone off, Bluetooth MIDI off",
            label: "Devices: Pad A missing, Pad B stale, Microphone access is off, Bluetooth MIDI access is off",
            severity: .error, lostItems: ["Pad A"]
        )
        let present = [Self.device("Pad C", .present)]
        let inputsOffPermissions = Self.permissions(microphone: .denied, bluetoothMIDI: .denied)
        let inputsOff = try Self.devicesSegment(present, permissions: inputsOffPermissions)
        Self.expectSegment(
            inputsOff, text: "Microphone off, Bluetooth MIDI off",
            label: "Devices: Microphone access is off, Bluetooth MIDI access is off", severity: .attention
        )
        let staleAndBluetooth = try Self.devicesSegment(
            [Self.device("Pad D", .stale)], permissions: Self.permissions(bluetoothMIDI: .restricted)
        )
        #expect(staleAndBluetooth.text == "1 stale, Bluetooth MIDI off")
        #expect(staleAndBluetooth.label == "Devices: Pad D stale, Bluetooth MIDI access is off")
    }

    @Test func localNetworkNeverAffectsDevices() throws {
        let rows = [Self.device("Pad A", .missing), Self.device("Pad B", .stale)]
        let baseline = try Self.devicesSegment(rows)
        for status in Self.allPermissionStatuses {
            let devices = try Self.devicesSegment(rows, permissions: Self.permissions(localNetwork: status))
            #expect(devices == baseline, "local network \(status)")
        }
        let quiet = try Self.devicesSegment([], permissions: Self.permissions(localNetwork: .denied))
        #expect(quiet.text == "No devices")
    }

    @Test func deviceNamesAreShownVerbatimWithoutTrimming() throws {
        let rows = [Self.device("  Pad  X ", .missing), Self.device("Interface \u{e9}", .missing)]
        let devices = try Self.devicesSegment(rows)
        #expect(devices.label == "Devices:   Pad  X  missing, Interface \u{e9} missing")
        #expect(devices.lostItems == ["  Pad  X ", "Interface \u{e9}"])
    }

    @Test func devicesSeverityIsMissingThenStaleOrBlockedThenNormal() throws {
        let micOff = Self.permissions(microphone: .denied)
        let present = [Self.device("Pad A", .present)]
        let stale = [Self.device("Pad A", .stale)]
        let missing = [Self.device("Pad A", .missing)]
        #expect(try Self.devicesSegment(present).severity == .normal)
        #expect(try Self.devicesSegment(present, permissions: micOff).severity == .attention)
        #expect(try Self.devicesSegment(stale).severity == .attention)
        #expect(try Self.devicesSegment(stale, permissions: micOff).severity == .attention)
        #expect(try Self.devicesSegment(missing).severity == .error)
        #expect(try Self.devicesSegment(missing, permissions: micOff).severity == .error)
    }

    @Test func deviceRowsKeepTheirInputOrderAndAreNeverSorted() throws {
        let forward = try Self.devicesSegment([Self.device("Zed", .missing), Self.device("Abe", .missing)])
        #expect(forward.label == "Devices: Zed missing, Abe missing")
        #expect(forward.lostItems == ["Zed", "Abe"])
        let reversed = try Self.devicesSegment([Self.device("Abe", .missing), Self.device("Zed", .missing)])
        #expect(reversed.label == "Devices: Abe missing, Zed missing")
        #expect(reversed.lostItems == ["Abe", "Zed"])
        #expect(forward.text == reversed.text)
    }
}
