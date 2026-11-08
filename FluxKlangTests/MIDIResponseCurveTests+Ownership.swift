import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// What `apply` may and may not change, and that a reshaped note-on still presses and releases in the note ledger.
extension MIDIResponseCurveTests {
    struct LedgerObservation: Equatable {
        let pressed: [MIDIRoutedOutput]
        let notesAfterPress: Int
        let released: [MIDIRoutedOutput]
        let notesAfterRelease: Int
    }

    static let ledgerInput = MIDIInputID(1)
    static let ledgerRoute = MIDIRouteID(10)

    static func velocityCurves() throws -> [MIDIResponseCurve] {
        [
            MIDIResponseCurve.linear(.velocity),
            try MIDIResponseCurve.fixedVelocity(1),
            try MIDIResponseCurve.fixedVelocity(127),
            try MIDIResponseCurve.limitedVelocity(low: 1, high: 1),
            try MIDIResponseCurve.limitedVelocity(low: 1, high: 127),
            try MIDIResponseCurve.limitedVelocity(low: 20, high: 90),
            try curve(.velocity, [(1, 1), (64, 32), (127, 127)]),
            try curve(.velocity, [(1, 1), (2, 127), (127, 127)]),
            try curve(.velocity, [(1, 127), (127, 127)])
        ]
    }

    static func fullTransform() throws -> MIDIValueTransform {
        let inverted = try curve(.controller, [(0, 127), (127, 0)])
        let constant = try curve(.controller, [(0, 5), (127, 5)])
        return try MIDIValueTransform.make(
            velocity: try MIDIResponseCurve.limitedVelocity(low: 20, high: 90),
            pressure: inverted,
            controllers: [entry(11, constant), entry(10, inverted)]
        )
    }

    /// Presses a note with the transformed note-on, then releases it with an untransformed note-off.
    static func observeLedger(velocity: UInt8, curve: MIDIResponseCurve) throws -> LedgerObservation {
        let rule = try #require(MIDIRoutingRule(input: ledgerInput, route: ledgerRoute))
        let routing = try #require(MIDIRouting(rules: [rule]))
        let transform = try MIDIValueTransform.make(velocity: curve, pressure: nil, controllers: [])
        var ledger = MIDINoteLedger()
        let noteOn = MIDI1Semantic.noteOn(channel: 1, note: 60, velocity: velocity)
        let pressEvent = MIDIPerformanceEvent(input: ledgerInput, message: transform.apply(noteOn))
        let pressed = try ledger.route(pressEvent, routing: routing)
        let notesAfterPress = ledger.notes.count
        let noteOff = MIDI1Semantic.noteOff(channel: 1, note: 60, velocity: 33)
        let releaseEvent = MIDIPerformanceEvent(input: ledgerInput, message: noteOff)
        let released = try ledger.route(releaseEvent, routing: routing)
        let notesAfterRelease = ledger.notes.count
        return LedgerObservation(
            pressed: pressed, notesAfterPress: notesAfterPress, released: released,
            notesAfterRelease: notesAfterRelease
        )
    }

    static func expectedObservation(velocity: UInt8) -> LedgerObservation {
        let pressMessage = MIDI1Semantic.noteOn(channel: 1, note: 60, velocity: velocity)
        let releaseMessage = MIDI1Semantic.noteOff(channel: 1, note: 60, velocity: 33)
        let pressed = [MIDIRoutedOutput(route: ledgerRoute, message: pressMessage)]
        let released = [MIDIRoutedOutput(route: ledgerRoute, message: releaseMessage)]
        return LedgerObservation(pressed: pressed, notesAfterPress: 1, released: released, notesAfterRelease: 0)
    }

    static func ledgerMismatches(curve: MIDIResponseCurve, expectedVelocity: (UInt8) -> UInt8) throws -> [UInt8] {
        var mismatches: [UInt8] = []
        for velocity: UInt8 in 1...127 {
            let observed = try observeLedger(velocity: velocity, curve: curve)
            let expected = expectedObservation(velocity: expectedVelocity(velocity))
            if observed != expected { mismatches.append(velocity) }
        }
        return mismatches
    }

    @Test func noSampledVelocityCurveOutputsZeroForAnyVelocityFromOneToOneHundredTwentySeven() throws {
        var zeroOrMissing: [UInt8] = []
        for curve in try Self.velocityCurves() {
            for input: UInt8 in 1...127 {
                let output = curve.output(for: input) ?? 0
                if output < 1 || output > 127 { zeroOrMissing.append(input) }
            }
        }
        #expect(zeroOrMissing == [])
    }

    @Test func noSampledVelocityCurveLetsAHarderHitSoundSofter() throws {
        var decreases: [UInt8] = []
        for curve in try Self.velocityCurves() {
            for input: UInt8 in 2...127 {
                let softer = curve.output(for: input - 1) ?? 0
                let harder = curve.output(for: input) ?? 0
                if harder < softer { decreases.append(input) }
            }
        }
        #expect(decreases == [])
    }

    @Test func aFixedCurveAndALimitedCurveWithEqualBoundsStillPressAndReleaseTheNoteInTheLedger() throws {
        var failingLevels: [UInt8] = []
        for level: UInt8 in 1...127 {
            let fixed = try MIDIResponseCurve.fixedVelocity(level)
            let limited = try MIDIResponseCurve.limitedVelocity(low: level, high: level)
            let fixedMismatches = try Self.ledgerMismatches(curve: fixed, expectedVelocity: { _ in level })
            let limitedMismatches = try Self.ledgerMismatches(curve: limited, expectedVelocity: { _ in level })
            if !fixedMismatches.isEmpty || !limitedMismatches.isEmpty { failingLevels.append(level) }
        }
        #expect(failingLevels == [])
    }

    @Test func theLinearCurveLeavesTheLedgerPressAndReleaseExactlyAsWithoutACurve() throws {
        let linear = MIDIResponseCurve.linear(.velocity)
        let mismatches = try Self.ledgerMismatches(curve: linear, expectedVelocity: { $0 })
        #expect(mismatches == [])
    }

    @Test func aTransformedNoteOnOfVelocityZeroStillReleasesThePressedNote() throws {
        let rule = try #require(MIDIRoutingRule(input: Self.ledgerInput, route: Self.ledgerRoute))
        let routing = try #require(MIDIRouting(rules: [rule]))
        let transform = try MIDIValueTransform.make(
            velocity: try MIDIResponseCurve.fixedVelocity(77), pressure: nil, controllers: []
        )
        var ledger = MIDINoteLedger()
        let press = MIDI1Semantic.noteOn(channel: 2, note: 61, velocity: 90)
        let pressEvent = MIDIPerformanceEvent(input: Self.ledgerInput, message: transform.apply(press))
        _ = try ledger.route(pressEvent, routing: routing)
        let zero = MIDI1Semantic.noteOn(channel: 2, note: 61, velocity: 0)
        let zeroEvent = MIDIPerformanceEvent(input: Self.ledgerInput, message: transform.apply(zero))
        let released = try ledger.route(zeroEvent, routing: routing)
        let releaseMessage = MIDI1Semantic.noteOff(channel: 2, note: 61, velocity: 64)
        let expected = [MIDIRoutedOutput(route: Self.ledgerRoute, message: releaseMessage)]
        #expect(released == expected)
        #expect(ledger.notes.isEmpty)
    }

    @Test func applyKeepsTheChannelAndNoteOfANoteOnAndReturnsAVelocityFromOneToOneHundredTwentySeven() throws {
        var violations = 0
        for curve in try Self.velocityCurves() {
            let transform = try MIDIValueTransform.make(velocity: curve, pressure: nil, controllers: [])
            for channel: UInt8 in 1...16 {
                for velocity: UInt8 in 1...127 {
                    let result = transform.apply(.noteOn(channel: channel, note: 60, velocity: velocity))
                    guard case let .noteOn(resultChannel, resultNote, resultVelocity) = result else {
                        violations += 1
                        continue
                    }
                    let atLeastOne = resultVelocity >= 1
                    let atMostMax = resultVelocity <= 127
                    if resultChannel != channel || resultNote != 60 || !atLeastOne || !atMostMax { violations += 1 }
                }
            }
        }
        #expect(violations == 0)
    }

    @Test func applyReturnsANoteOnOfVelocityZeroAndEveryNoteOffUnchanged() throws {
        let transform = try Self.fullTransform()
        var changed = 0
        for channel: UInt8 in 1...16 {
            for note: UInt8 in 0...127 {
                let zero = MIDI1Semantic.noteOn(channel: channel, note: note, velocity: 0)
                if transform.apply(zero) != zero { changed += 1 }
                for velocity: UInt8 in 0...127 {
                    let off = MIDI1Semantic.noteOff(channel: channel, note: note, velocity: velocity)
                    if transform.apply(off) != off { changed += 1 }
                }
            }
        }
        #expect(changed == 0)
    }

    @Test func applyOnlyEverChangesTheDataValueByte() throws {
        let transform = try Self.fullTransform()
        var violations = 0
        for channel: UInt8 in 1...16 {
            for note: UInt8 in 0...127 {
                for value: UInt8 in 0...127 {
                    for message in Self.samples(channel: channel, note: note, value: value) {
                        let result = transform.apply(message)
                        if !Self.sameExceptValue(message, result) || !result.hasRoutableData { violations += 1 }
                    }
                }
            }
        }
        #expect(violations == 0)
    }

    static func samples(channel: UInt8, note: UInt8, value: UInt8) -> [MIDI1Semantic] {
        [
            .noteOn(channel: channel, note: note, velocity: value),
            .polyphonicPressure(channel: channel, note: note, pressure: value),
            .channelPressure(channel: channel, pressure: value),
            .controlChange(channel: channel, controller: 10, value: value),
            .controlChange(channel: channel, controller: 11, value: value),
            .controlChange(channel: channel, controller: note, value: value),
            .programChange(channel: channel, program: value),
            .pitchBend(channel: channel, value: UInt16(value) * 128),
            .noteOff(channel: channel, note: note, velocity: value)
        ]
    }

    static func sameExceptValue(_ original: MIDI1Semantic, _ result: MIDI1Semantic) -> Bool {
        switch (original, result) {
        case let (.noteOn(channelA, noteA, _), .noteOn(channelB, noteB, _)),
             let (.polyphonicPressure(channelA, noteA, _), .polyphonicPressure(channelB, noteB, _)):
            return channelA == channelB && noteA == noteB
        case let (.channelPressure(channelA, _), .channelPressure(channelB, _)):
            return channelA == channelB
        case let (.controlChange(channelA, controllerA, _), .controlChange(channelB, controllerB, _)):
            return channelA == channelB && controllerA == controllerB
        case (.noteOff, _), (.programChange, _), (.pitchBend, _), (.systemCommon, _), (.realTime, _), (.sysEx, _):
            return original == result
        case (.noteOn, _), (.polyphonicPressure, _), (.channelPressure, _), (.controlChange, _):
            return false
        }
    }

    @Test func pressureCurveReshapesPolyphonicAndChannelPressureAndNothingElse() throws {
        let transform = try Self.fullTransform()
        let poly = transform.apply(.polyphonicPressure(channel: 3, note: 60, pressure: 10))
        let channel = transform.apply(.channelPressure(channel: 4, pressure: 100))
        let program = transform.apply(.programChange(channel: 3, program: 10))
        let expectedPoly = MIDI1Semantic.polyphonicPressure(channel: 3, note: 60, pressure: 117)
        let expectedChannel = MIDI1Semantic.channelPressure(channel: 4, pressure: 27)
        let expectedProgram = MIDI1Semantic.programChange(channel: 3, program: 10)
        #expect(poly == expectedPoly)
        #expect(channel == expectedChannel)
        #expect(program == expectedProgram)
    }

    @Test func aRegisteredControllerCurveReshapesItsControllerAndNoOtherController() throws {
        let transform = try Self.fullTransform()
        let inverted = transform.apply(.controlChange(channel: 5, controller: 10, value: 30))
        let constant = transform.apply(.controlChange(channel: 5, controller: 11, value: 30))
        let unregistered = transform.apply(.controlChange(channel: 5, controller: 12, value: 30))
        let sustain = transform.apply(.controlChange(channel: 5, controller: 64, value: 127))
        let expectedInverted = MIDI1Semantic.controlChange(channel: 5, controller: 10, value: 97)
        let expectedConstant = MIDI1Semantic.controlChange(channel: 5, controller: 11, value: 5)
        let expectedUnregistered = MIDI1Semantic.controlChange(channel: 5, controller: 12, value: 30)
        let expectedSustain = MIDI1Semantic.controlChange(channel: 5, controller: 64, value: 127)
        #expect(inverted == expectedInverted)
        #expect(constant == expectedConstant)
        #expect(unregistered == expectedUnregistered)
        #expect(sustain == expectedSustain)
    }

    @Test func aVelocityCurveReshapesANoteOnVelocityAndNothingElseOfIt() throws {
        let transform = try Self.fullTransform()
        let result = transform.apply(.noteOn(channel: 7, note: 48, velocity: 64))
        let expected = MIDI1Semantic.noteOn(channel: 7, note: 48, velocity: 55)
        #expect(result == expected)
    }

    @Test func applyReturnsMessagesOfOtherKindsUnchanged() throws {
        let transform = try Self.fullTransform()
        let others: [MIDI1Semantic] = [
            .programChange(channel: 1, program: 5),
            .pitchBend(channel: 2, value: 8_192),
            .systemCommon(status: 0xF2, data1: 1, data2: 2),
            .realTime(status: 0xF8),
            .sysEx(payload: [1, 2, 3])
        ]
        let results = others.map { transform.apply($0) }
        #expect(results == others)
    }

    @Test func applyReturnsMessagesWithOutOfRangeDataBytesUnchanged() throws {
        let transform = try Self.fullTransform()
        let forged: [MIDI1Semantic] = [
            .noteOn(channel: 1, note: 60, velocity: 200),
            .noteOn(channel: 1, note: 128, velocity: 64),
            .polyphonicPressure(channel: 1, note: 60, pressure: 128),
            .polyphonicPressure(channel: 1, note: 200, pressure: 10),
            .channelPressure(channel: 1, pressure: 255),
            .controlChange(channel: 1, controller: 10, value: 130),
            .controlChange(channel: 1, controller: 130, value: 10),
            .pitchBend(channel: 1, value: 16_384)
        ]
        let results = forged.map { transform.apply($0) }
        #expect(results == forged)
    }

    @Test func theIdentityTransformReturnsEverySampledMessageUnchanged() {
        var changed = 0
        for channel: UInt8 in 1...16 {
            for value: UInt8 in 0...127 {
                let samples = Self.samples(channel: channel, note: 60, value: value)
                changed += samples.filter { MIDIValueTransform.identity.apply($0) != $0 }.count
            }
        }
        #expect(changed == 0)
    }

    @Test func applyIsDeterministicForTheSameTransformAndMessage() throws {
        let first = try Self.fullTransform()
        let second = try Self.fullTransform()
        var differing = 0
        for value: UInt8 in 0...127 {
            let samples = Self.samples(channel: 1, note: 60, value: value)
            differing += samples.filter { first.apply($0) != second.apply($0) }.count
        }
        #expect(differing == 0)
    }
}

// MARK: - Source scan

extension MIDIResponseCurveTests {
    static let productionFiles = ["MIDIResponseCurve.swift", "MIDIValueTransform.swift", "MIDICurveRefusal.swift"]
    static let forbiddenWords = [
        "Double", "Float", "Date(", "Clock", "Task", "import SwiftUI", "DispatchQueue", "default:"
    ]

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/MIDI/Performance/Curves",
            "../../Sources/FluxKlang/Shared/MIDI/Performance/Curves"
        ]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(productionFiles[0]).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    static func findings(in text: String) -> [String] {
        forbiddenWords.filter { text.contains($0) }
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the curve sources are not next to the tests"))
    func theCurveSourcesContainNoFloatingPointClockTaskUiQueueOrDefaultCase() throws {
        let directory = try #require(Self.sourceDirectory())
        for name in Self.productionFiles {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains("MIDI"), "\(name)")
            #expect(Self.findings(in: text) == [], "\(name)")
        }
    }

    @Test func theSourceScannerFlagsEveryForbiddenWordAndNothingBesides() {
        for word in Self.forbiddenWords {
            let flagged = Self.findings(in: "let item = \(word)")
            #expect(flagged == [word], "\(word)")
        }
        let clean = Self.findings(in: "let table: [UInt8] = []")
        #expect(clean == [])
    }
}
