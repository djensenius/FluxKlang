import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialRouteStateTests {
    static func identityAvailability() throws -> SpatialRouteAvailability {
        try derive([
            route("r.a", device: "dev.a", channels: [0, 1], uid: "uid.a"),
            route("r.b", device: "dev.b", channels: [2, 3], uid: "uid.b"),
            route(rid("r.in"), direction: .input)
        ])
    }

    static func identityLayout() throws -> SpatialLayout {
        try layout([
            speaker(sid("s.1"), route: rid("r.a")), speaker(sid("s.2"), route: rid("r.b")),
            speaker(sid("s.3"), route: nil), speaker(sid("s.4"), route: rid("r.in")),
            speaker(sid("s.5"), route: rid("r.nowhere"))
        ])
    }

    /// The flag kind of speaker `s.1` (route `r.a`, unit `uid.a`, channels 0 and 1) for one measurement.
    fileprivate static func flagKind(
        _ measured: SpatialSpeakerMeasurement?,
        availability: SpatialRouteAvailability? = nil
    ) throws -> SpatialCalibrationFlag.Kind? {
        let flags = try SpatialCalibrationBinding.check(
            calibration: calibration([sid("s.1")]),
            layout: identityLayout(),
            measured: measured.map { [$0] } ?? [],
            current: availability ?? identityAvailability()
        )
        #expect(flags.map(\.speaker) == [sid("s.1")])
        return flags.first?.kind
    }

    @Test
    func makeStoresTheExactFieldsWithSortedChannels() throws {
        let identity = try SpatialMeasurementIdentity.make(
            route: Self.rid("r.a"), deviceUID: " uid.A ", channels: [5, 2, 9], host: Self.hostB
        )
        #expect(identity.route == Self.rid("r.a"))
        #expect(identity.uid.value == " uid.A ")
        #expect(identity.channels == [2, 5, 9])
        #expect(identity.host == Self.hostB)
    }

    @Test
    func makeUIDLengthIsAtMostOneThousandTwentyFourBytesAndBlankIsEmpty() throws {
        let id = Self.rid("r.a")
        func make(_ uid: String) -> SpatialRouteRefusal? {
            do throws(SpatialRouteRefusal) {
                _ = try SpatialMeasurementIdentity.make(route: id, deviceUID: uid, channels: [0], host: Self.hostA)
                return nil
            } catch {
                return error
            }
        }
        #expect(make(String(repeating: "a", count: 1_024)) == nil)
        #expect(make(String(repeating: "\u{e9}", count: 512)) == nil)
        #expect(make("a") == nil)
        #expect(make(String(repeating: "a", count: 1_025)) == .uidTooLong(id, bytes: 1_025))
        #expect(make(String(repeating: "\u{e9}", count: 511) + "abc") == .uidTooLong(id, bytes: 1_025))
        for blank in ["", " ", "\t\n", "\u{00A0}", "\u{2003}"] {
            #expect(make(blank) == .emptyUID(id))
        }
        #expect(make("\u{200B}") == .emptyUID(id))
    }

    @Test
    func blankUIDMatchesTheDeviceContractsTrimCheckOnBoundaryScalars() {
        let ranges: [ClosedRange<UInt32>] = [
            0x09...0x0D, 0x20...0x20, 0x85...0x85, 0xA0...0xA0, 0x1680...0x1680, 0x2000...0x200B,
            0x2028...0x2029, 0x202F...0x202F, 0x205F...0x205F, 0x3000...0x3000, 0xFEFF...0xFEFF
        ]
        for scalar in ranges.flatMap({ Array($0) }).compactMap(Unicode.Scalar.init) {
            for candidate in [String(scalar), String(scalar) + String(scalar), "a" + String(scalar)] {
                let contract = candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                #expect(SpatialUnitUID.isBlank(candidate) == contract, "U+\(String(scalar.value, radix: 16))")
            }
        }
    }

    @Test
    func makeChannelCountIsOneThroughSixtyFourAndValuesAreNonNegativeAndDistinct() throws {
        let id = Self.rid("r.a")
        func make(_ channels: [Int]) -> SpatialRouteRefusal? {
            do throws(SpatialRouteRefusal) {
                _ = try SpatialMeasurementIdentity.make(route: id, deviceUID: "u", channels: channels, host: Self.hostA)
                return nil
            } catch {
                return error
            }
        }
        #expect(make([0]) == nil)
        #expect(make(Array(0..<64)) == nil)
        #expect(make([Int.max]) == nil)
        #expect(make([]) == .channelCountOutOfRange(id, count: 0))
        #expect(make(Array(0..<65)) == .channelCountOutOfRange(id, count: 65))
        #expect(make([-1]) == .negativeChannel(id, channel: -1))
        #expect(make([3, Int.min]) == .negativeChannel(id, channel: Int.min))
        #expect(make([4, 2, 4]) == .duplicateChannel(id, channel: 4))
    }

    @Test
    func unitUIDsAreComparedByUnicodeScalarsNotByCharacters() throws {
        let precomposed = "\u{e9}"
        let decomposed = "e\u{301}"
        #expect(precomposed == decomposed)
        #expect(!precomposed.unicodeScalars.elementsEqual(decomposed.unicodeScalars))
        let one = try SpatialMeasurementIdentity.make(
            route: Self.rid("r.a"), deviceUID: precomposed, channels: [0], host: Self.hostA
        )
        let two = try SpatialMeasurementIdentity.make(
            route: Self.rid("r.a"), deviceUID: decomposed, channels: [0], host: Self.hostA
        )
        let same = try SpatialMeasurementIdentity.make(
            route: Self.rid("r.a"), deviceUID: precomposed, channels: [0], host: Self.hostA
        )
        #expect(one != two)
        #expect(one == same)
        #expect(Set([one, two, same]).count == 2)
    }

    @Test
    func identitiesDifferByEveryField() throws {
        func make(route: StaticString = "r.a", uid: String = "u", channels: [Int] = [0, 1],
                  host: HostID = Self.hostA) throws -> SpatialMeasurementIdentity {
            try SpatialMeasurementIdentity.make(route: Self.rid(route), deviceUID: uid, channels: channels, host: host)
        }
        let base = try make()
        #expect(try make(channels: [1, 0]) == base)
        #expect(try make(route: "r.b") != base)
        #expect(try make(uid: "v") != base)
        #expect(try make(channels: [0, 2]) != base)
        #expect(try make(host: Self.hostB) != base)
    }

    @Test
    func aMeasurementOnTheSameRouteUnitAndChannelsMatchesWhateverTheChannelOrder() throws {
        let sameOrder = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"))
        #expect(try Self.flagKind(sameOrder) == .matches)
        let swapped = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"), channels: [1, 0])
        #expect(try Self.flagKind(swapped) == .matches)
    }

    @Test
    func aCalibratedSpeakerWithoutAMeasurementIsFlaggedNoMeasurement() throws {
        #expect(try Self.flagKind(nil) == .noMeasurement)
    }

    @Test
    func theSameRouteOnAnotherUnitIsUnitChanged() throws {
        let measured = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"), uid: "uid.other")
        #expect(try Self.flagKind(measured) == .unitChanged)
    }

    @Test
    func aSpeakerNowOnAnotherRouteIsRemapped() throws {
        let measured = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.b"), uid: "uid.b", channels: [2, 3])
        #expect(try Self.flagKind(measured) == .remapped)
    }

    @Test
    func theSameUnitWithAnotherChannelSetIsRemapped() throws {
        let measured = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"), channels: [0, 2])
        #expect(try Self.flagKind(measured) == .remapped)
        let narrower = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"), channels: [0])
        #expect(try Self.flagKind(narrower) == .remapped)
    }

    @Test
    func aMeasurementFromAnotherHostIsOtherHostEvenIfRouteAndUnitAgree() throws {
        let measured = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"), host: Self.hostB)
        #expect(try Self.flagKind(measured) == .otherHost)
    }

    @Test
    func unmappedUnavailableAndAbsentRoutesAreRouteUnavailable() throws {
        let availability = try Self.identityAvailability()
        let layout = try Self.identityLayout()
        let calibration = try Self.calibration([Self.sid("s.3"), Self.sid("s.4"), Self.sid("s.5")])
        let measured = try ["s.3", "s.4", "s.5"].map {
            try Self.measurement(try SpeakerID($0), route: Self.rid("r.a"))
        }
        let flags = try SpatialCalibrationBinding.check(
            calibration: calibration, layout: layout, measured: measured, current: availability
        )
        #expect(flags.map(\.speaker) == [Self.sid("s.3"), Self.sid("s.4"), Self.sid("s.5")])
        #expect(flags.map(\.kind) == [.routeUnavailable, .routeUnavailable, .routeUnavailable])
    }

    @Test
    func aDeviceIDNeverSubstitutesForTheUnitUID() throws {
        let measured = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"))
        let movedDevice = try Self.derive([Self.route("r.a", device: "dev.c", uid: "uid.a")])
        #expect(try Self.flagKind(measured, availability: movedDevice) == .matches)
        let sameDevice = try Self.derive([Self.route("r.a", device: "dev.a", uid: "uid.z")])
        #expect(try Self.flagKind(measured, availability: sameDevice) == .unitChanged)
    }

    @Test
    func canonicallyEquivalentUIDsAreDifferentUnits() throws {
        let precomposed = try Self.derive([Self.route("r.a", uid: "\u{e9}")])
        let decomposed = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"), uid: "e\u{301}")
        #expect(try Self.flagKind(decomposed, availability: precomposed) == .unitChanged)
        let same = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"), uid: "\u{e9}")
        #expect(try Self.flagKind(same, availability: precomposed) == .matches)
    }

    @Test
    func onlyCalibratedSpeakersAreFlaggedInAscendingSpeakerOrder() throws {
        let flags = try SpatialCalibrationBinding.check(
            calibration: Self.calibration([Self.sid("s.2"), Self.sid("s.1")]),
            layout: Self.identityLayout(),
            measured: [Self.measurement(Self.sid("s.4"), route: Self.rid("r.in")),
                       Self.measurement(Self.sid("s.2"), route: Self.rid("r.b"), uid: "uid.b", channels: [2, 3])],
            current: Self.identityAvailability()
        )
        #expect(flags.map(\.speaker) == [Self.sid("s.1"), Self.sid("s.2")])
        #expect(flags.map(\.kind) == [.noMeasurement, .matches])
    }

    @Test
    func aCalibrationWithNoEntriesYieldsNoFlagsEvenWithMeasurements() throws {
        let flags = try SpatialCalibrationBinding.check(
            calibration: .empty, layout: Self.identityLayout(),
            measured: [Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"))],
            current: Self.identityAvailability()
        )
        #expect(flags.isEmpty)
    }

    @Test
    func measurementCountIsAtMostSixtyFourAndEveryNormalCallLeavesItsInputsUnchanged() throws {
        let ids = try (0..<64).map { try SpeakerID(Self.padded($0, prefix: "s")) }
        let layout = try Self.layout(ids.map { try Self.speaker($0, route: Self.rid("r.a")) })
        let calibration = try Self.calibration(ids)
        let availability = try Self.identityAvailability()
        let measured = try ids.map { try Self.measurement($0, route: Self.rid("r.a")) }
        let layoutBefore = layout
        let calibrationBefore = calibration
        let measuredBefore = measured
        let flags = try SpatialCalibrationBinding.check(
            calibration: calibration, layout: layout, measured: measured, current: availability
        )
        #expect(flags.count == 64)
        #expect(flags.allSatisfy { $0.kind == .matches })
        #expect(layout == layoutBefore)
        #expect(calibration == calibrationBefore)
        #expect(measured == measuredBefore)
        let overflowing = measured + [try Self.measurement(ids[0], route: Self.rid("r.a"))]
        let refusal = Self.checkRefusal(
            calibration: calibration, layout: layout, measured: overflowing, current: availability
        )
        #expect(refusal == .tooManyMeasurements(65))
    }

    @Test
    func aRefusedCheckLeavesEveryInputUnchanged() throws {
        let calibration = try Self.calibration([Self.sid("s.1")])
        let layout = try Self.identityLayout()
        let availability = try Self.identityAvailability()
        let measured = [
            try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a")),
            try Self.measurement(Self.sid("s.1"), route: Self.rid("r.b"))
        ]
        let calibrationBefore = calibration
        let layoutBefore = layout
        let availabilityBefore = availability
        let measuredBefore = measured
        let refusal = Self.checkRefusal(
            calibration: calibration, layout: layout, measured: measured, current: availability
        )
        #expect(refusal == .duplicateMeasurement(Self.sid("s.1")))
        #expect(calibration == calibrationBefore)
        #expect(layout == layoutBefore)
        #expect(availability == availabilityBefore)
        #expect(measured == measuredBefore)
    }
}
