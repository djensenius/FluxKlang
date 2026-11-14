import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Builders for the rig identity matching suites.
enum RigIdentityFixture {
    static func deviceID(_ raw: String) throws -> DeviceID { try DeviceID(raw) }

    /// An observed descriptor. The default UID is `uid-<id>`, so two ids never share a UID by accident.
    static func device(_ id: String, uid: String? = nil, presence: DevicePresence = .present,
                       evidence: Set<IdentityEvidence> = [.deviceUID]) throws -> DeviceDescriptor {
        try DeviceDescriptor(
            id: DeviceID(id), kind: .audioInterface, layout: nil, binding: .reported,
            identity: DeviceIdentity(.init(uid: uid ?? "uid-\(id)", evidence: evidence)), presence: presence
        )
    }

    static func saved(_ id: String, uid: String? = nil, required: Bool = true,
                      role: String? = nil) throws -> RigSavedDevice {
        try RigSavedDevice.make(id: DeviceID(id), uid: uid ?? "uid-\(id)",
                                role: role.map { try RoleID($0) }, required: required)
    }

    static func rig(_ id: String, _ devices: [RigSavedDevice]) throws -> RigSavedRig {
        try RigSavedRig.make(id: RigProfileID(id), devices: devices)
    }

    /// A rig built without validation, as a caller could.
    static func handBuilt(_ id: String, _ devices: [RigSavedDevice]) throws -> RigSavedRig {
        try RigSavedRig(id: RigProfileID(id), devices: devices)
    }

    /// `count` saved devices `dev.000`... with distinct UIDs, all required.
    static func savedRun(_ count: Int, prefix: String = "dev") throws -> [RigSavedDevice] {
        try (0..<count).map { try saved("\(prefix).\(pad($0))") }
    }

    static func observedRun(_ count: Int, prefix: String = "dev") throws -> [DeviceDescriptor] {
        try (0..<count).map { try device("\(prefix).\(pad($0))") }
    }

    static func pad(_ value: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, 4 - text.count)) + text
    }

    /// The refusal `body` throws, or nil. The closures only call this slice's typed-throwing functions, so any
    /// other error would show as nil and fail the comparison with the expected refusal.
    static func refusal<Value>(_ body: () throws -> Value) -> RigIdentityRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? RigIdentityRefusal
        }
    }

    static func outcome(_ report: RigMatchReport, _ id: String) throws -> RigMatchOutcome {
        try #require(report.rows.first { $0.saved.id.rawValue == id }).outcome
    }

    static func match(_ rig: RigSavedRig, _ observed: [DeviceDescriptor]) throws -> RigMatchReport {
        try RigIdentityMatcher.match(rig: rig, observed: observed)
    }

    /// "café" spelled with one precomposed scalar and with a combining accent: canonically equal, scalar-distinct.
    static let precomposed = "caf\u{00E9}"
    static let decomposed = "cafe\u{0301}"
}

@Suite("Rig identity matching: saved devices and rigs", .productionAccessAudit)
struct RigIdentityMatchTests {
    typealias Fixture = RigIdentityFixture

    @Test func savedUIDAcceptsExactly1024BytesAndRefuses1025() throws {
        let atLimit = String(repeating: "u", count: 1_024)
        let device = try RigSavedDevice.make(id: Fixture.deviceID("dev.a"), uid: atLimit, role: nil, required: true)
        #expect(device.uid == atLimit)
        let over = Fixture.refusal {
            try RigSavedDevice.make(id: DeviceID(validated: "dev.a"), uid: String(repeating: "u", count: 1_025),
                                    role: nil, required: true)
        }
        #expect(over == .uidTooLong(1_025))
    }

    @Test func savedUIDLengthIsCountedInUTF8BytesNotCharacters() throws {
        let threeBytes = "\u{20AC}"
        let fits = String(repeating: threeBytes, count: 341)
        #expect(fits.utf8.count == 1_023 && fits.count == 341)
        _ = try RigSavedDevice.make(id: Fixture.deviceID("dev.a"), uid: fits, role: nil, required: true)
        let tooLong = String(repeating: threeBytes, count: 342)
        let refusal = Fixture.refusal {
            try RigSavedDevice.make(id: DeviceID(validated: "dev.a"), uid: tooLong, role: nil, required: true)
        }
        #expect(refusal == .uidTooLong(1_026))
    }

    @Test func savedUIDRefusesEmptyAndWhitespaceOnly() throws {
        for blank in ["", " ", "  \n\t "] {
            let refusal = Fixture.refusal {
                try RigSavedDevice.make(id: DeviceID(validated: "dev.a"), uid: blank, role: nil, required: true)
            }
            #expect(refusal == .emptyUID)
        }
        let padded = try RigSavedDevice.make(id: Fixture.deviceID("dev.a"), uid: " a ", role: nil, required: true)
        #expect(padded.uid == " a ")
    }

    @Test func savedUIDTooLongOutranksBlank() {
        let blankAndLong = String(repeating: " ", count: 1_025)
        let refusal = Fixture.refusal {
            try RigSavedDevice.make(id: DeviceID(validated: "dev.a"), uid: blankAndLong, role: nil, required: true)
        }
        #expect(refusal == .uidTooLong(1_025))
    }

    @Test func savedDeviceKeepsItsFields() throws {
        let device = try Fixture.saved("dev.a", uid: "uid-a", required: false, role: "rol.mains")
        #expect(device.id == (try DeviceID("dev.a")))
        #expect(device.uid == "uid-a")
        #expect(device.role == (try RoleID("rol.mains")))
        #expect(!device.required)
        let plain = try Fixture.saved("dev.a", uid: "uid-a", required: false)
        #expect(plain.role == nil)
        #expect(plain != device)
        #expect(try Fixture.saved("dev.a", uid: "uid-a", required: true, role: "rol.mains") != device)
        #expect(try Fixture.saved("dev.b", uid: "uid-a", required: false, role: "rol.mains") != device)
        #expect(try Fixture.saved("dev.a", uid: "uid-a", required: false, role: "rol.mains") == device)
    }

    @Test func canonicallyEquivalentSavedUIDsStayDistinct() throws {
        #expect(Fixture.precomposed == Fixture.decomposed)
        let first = try Fixture.saved("dev.a", uid: Fixture.precomposed)
        let second = try Fixture.saved("dev.a", uid: Fixture.decomposed)
        #expect(first != second)
        #expect(Set([first, second]).count == 2)
        #expect(first == (try Fixture.saved("dev.a", uid: Fixture.precomposed)))
    }

    @Test func rigFactoryAcceptsEmptyRigAnd64Devices() throws {
        let empty = try Fixture.rig("rig.empty", [])
        #expect(empty.devices.isEmpty)
        let full = try Fixture.rig("rig.full", Fixture.savedRun(64))
        #expect(full.devices.count == 64)
    }

    @Test func rigFactoryRefuses65Devices() throws {
        let devices = try Fixture.savedRun(65)
        let refusal = Fixture.refusal { try RigSavedRig.make(id: RigProfileID(validated: "rig.a"), devices: devices) }
        #expect(refusal == .tooManyDevices(count: 65, maximum: 64))
    }

    @Test func rigFactoryReportsSmallestRepeatedDeviceIDInEitherOrder() throws {
        let devices = try [Fixture.saved("dev.c", uid: "uc"), Fixture.saved("dev.b", uid: "ub"),
                           Fixture.saved("dev.c", uid: "uc2"), Fixture.saved("dev.b", uid: "ub2"),
                           Fixture.saved("dev.a", uid: "ua")]
        for order in [devices, Array(devices.reversed())] {
            let refusal = Fixture.refusal { try RigSavedRig.make(id: RigProfileID(validated: "rig.a"), devices: order) }
            #expect(refusal == .duplicateDevice(try DeviceID("dev.b")))
        }
    }

    @Test func rigFactoryRefusesRepeatedUIDsByScalarsInEitherOrder() throws {
        let devices = try [Fixture.saved("dev.c", uid: "shared"), Fixture.saved("dev.a", uid: "shared"),
                           Fixture.saved("dev.b", uid: "other")]
        for order in [devices, Array(devices.reversed())] {
            let refusal = Fixture.refusal { try RigSavedRig.make(id: RigProfileID(validated: "rig.a"), devices: order) }
            #expect(refusal == .duplicateUID(first: try DeviceID("dev.a"), second: try DeviceID("dev.c")))
        }
    }

    @Test func rigFactoryKeepsCanonicallyEquivalentUIDsAsTwoDevices() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: Fixture.precomposed),
                                            Fixture.saved("dev.b", uid: Fixture.decomposed)])
        #expect(rig.devices.count == 2)
    }

    @Test func rigRefusesTooManyDevicesBeforeRepeatedIDs() throws {
        var devices = try Fixture.savedRun(65)
        devices[64] = try Fixture.saved("dev.0000", uid: "other-uid")
        let rig = devices
        let refusal = Fixture.refusal { try RigSavedRig.make(id: RigProfileID(validated: "rig.a"), devices: rig) }
        #expect(refusal == .tooManyDevices(count: 65, maximum: 64))
    }

    @Test func rigRefusesRepeatedDeviceIDBeforeRepeatedUID() throws {
        let devices = try [Fixture.saved("dev.a", uid: "u1"), Fixture.saved("dev.a", uid: "u1"),
                           Fixture.saved("dev.b", uid: "u2"), Fixture.saved("dev.c", uid: "u2")]
        for order in [devices, Array(devices.reversed())] {
            let refusal = Fixture.refusal { try RigSavedRig.make(id: RigProfileID(validated: "rig.a"), devices: order) }
            #expect(refusal == .duplicateDevice(try DeviceID("dev.a")))
        }
    }
}
