//
//  PerformXYTests+Refusals.swift
//  FluxKlangTests
//
//  What the pad refuses and in which order: the pad factory (capture radius, then the x position, then the y
//  position), and an entry or an adjustment that is refused before a waiting pad would hold it. Also a scripted run
//  repeated, the two outcome cases, and a scan of the three production files.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformXYTests {
    static func refusalOfPad(radius: Int, positionX: Int, positionY: Int) -> PerformXYRefusal? {
        do {
            _ = try PerformXYPad.make(
                xRange: range(-100, 100), yRange: range(-50, 50), position: point(positionX, positionY),
                pickup: .engaged, captureRadius: radius
            )
            return nil
        } catch {
            return error
        }
    }

    // swiftlint:disable:next identifier_name
    static func refusalOfEntry(_ pad: PerformXYPad, x: Int?, y: Int?) -> PerformXYRefusal? {
        do {
            _ = try pad.entering(x: x, y: y)
            return nil
        } catch {
            return error
        }
    }

    static func refusalOfAdjust(_ pad: PerformXYPad, _ axis: PerformXYAxis, steps: Int) -> PerformXYRefusal? {
        do {
            _ = try pad.adjusting(axis, by: steps)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Pad factory

    @Test
    func padAcceptsCaptureRadiusZeroAndTheLimitAndRefusesOneBeyondEitherSide() throws {
        let exact = try Self.pad(0, 0, .engaged, radius: 0)
        #expect(exact.captureRadius == 0)
        let widest = try Self.pad(0, 0, .engaged, radius: 1_000_000)
        #expect(widest.captureRadius == 1_000_000)
        #expect(Self.refusalOfPad(radius: -1, positionX: 0, positionY: 0) == .captureRadiusOutOfLimit(-1))
        #expect(Self.refusalOfPad(radius: 1_000_001, positionX: 0, positionY: 0) == .captureRadiusOutOfLimit(1_000_001))
        #expect(Self.refusalOfPad(radius: Int.min, positionX: 0, positionY: 0) == .captureRadiusOutOfLimit(Int.min))
        #expect(Self.refusalOfPad(radius: Int.max, positionX: 0, positionY: 0) == .captureRadiusOutOfLimit(Int.max))
    }

    @Test
    func padRefusesAPositionOutsideEitherRangeAndAcceptsTheBounds() throws {
        #expect(Self.refusalOfPad(radius: 0, positionX: 101, positionY: 0) == .positionOutsideRange(.x))
        #expect(Self.refusalOfPad(radius: 0, positionX: -101, positionY: 0) == .positionOutsideRange(.x))
        #expect(Self.refusalOfPad(radius: 0, positionX: 0, positionY: 51) == .positionOutsideRange(.y))
        #expect(Self.refusalOfPad(radius: 0, positionX: 0, positionY: -51) == .positionOutsideRange(.y))
        #expect(Self.refusalOfPad(radius: 0, positionX: Int.max, positionY: 0) == .positionOutsideRange(.x))
        #expect(Self.refusalOfPad(radius: 0, positionX: 0, positionY: Int.min) == .positionOutsideRange(.y))
        let corner = try Self.pad(-100, 50, .engaged)
        #expect(corner.position == Self.point(-100, 50))
        let opposite = try Self.pad(100, -50, .engaged)
        #expect(opposite.position == Self.point(100, -50))
    }

    @Test
    func padReportsACaptureRadiusOutsideTheSpanBeforeAPositionOutsideTheRange() {
        #expect(Self.refusalOfPad(radius: -1, positionX: 500, positionY: 0) == .captureRadiusOutOfLimit(-1))
        let radiusRefusal = Self.refusalOfPad(radius: 1_000_001, positionX: 0, positionY: 500)
        #expect(radiusRefusal == .captureRadiusOutOfLimit(1_000_001))
        #expect(Self.refusalOfPad(radius: 0, positionX: 500, positionY: 0) == .positionOutsideRange(.x))
    }

    @Test
    func padReportsAnXPositionOutsideTheRangeBeforeAYPositionOutsideTheRange() {
        #expect(Self.refusalOfPad(radius: 0, positionX: 101, positionY: 51) == .positionOutsideRange(.x))
        #expect(Self.refusalOfPad(radius: 0, positionX: -500, positionY: -500) == .positionOutsideRange(.x))
        #expect(Self.refusalOfPad(radius: 0, positionX: 100, positionY: 51) == .positionOutsideRange(.y))
    }

    @Test
    func padKeepsTheRangesPositionPickupAndRadiusItWasBuiltWith() throws {
        let xRange = try Self.range(-8, 9)
        let yRange = try Self.range(3, 3)
        let pad = try PerformXYPad.make(
            xRange: xRange, yRange: yRange, position: Self.point(-8, 3), pickup: .waiting, captureRadius: 4
        )
        #expect(pad.xRange.lower == -8)
        #expect(pad.xRange.upper == 9)
        #expect(pad.yRange.lower == 3)
        #expect(pad.yRange.upper == 3)
        #expect(pad.position == Self.point(-8, 3))
        #expect(pad.pickup == .waiting)
        #expect(pad.captureRadius == 4)
    }

    // MARK: - Input refusals come before the waiting hold

    @Test
    func enteringNeitherAxisIsRefusedOnWaitingAndEngagedPadsAndNotHeld() throws {
        let waiting = try Self.pad(0, 0, .waiting)
        let engaged = try Self.pad(0, 0, .engaged)
        #expect(Self.refusalOfEntry(waiting, x: nil, y: nil) == .noAxisGiven)
        #expect(Self.refusalOfEntry(engaged, x: nil, y: nil) == .noAxisGiven)
        Self.expectHold(try waiting.entering(x: 5, y: nil), requested: Self.point(5, 0), current: Self.point(0, 0))
        Self.expectHold(try waiting.entering(x: nil, y: 5), requested: Self.point(0, 5), current: Self.point(0, 0))
    }

    @Test
    func adjustingByZeroStepsIsRefusedOnWaitingAndEngagedPadsAndNotHeld() throws {
        let waiting = try Self.pad(0, 0, .waiting)
        let engaged = try Self.pad(0, 0, .engaged)
        #expect(Self.refusalOfAdjust(waiting, .x, steps: 0) == .stepIsZero)
        #expect(Self.refusalOfAdjust(waiting, .y, steps: 0) == .stepIsZero)
        #expect(Self.refusalOfAdjust(engaged, .x, steps: 0) == .stepIsZero)
        #expect(Self.refusalOfAdjust(engaged, .y, steps: 0) == .stepIsZero)
        Self.expectHold(try waiting.adjusting(.x, by: 1), requested: Self.point(1, 0), current: Self.point(0, 0))
    }

    // MARK: - Repeatability and outcome cases

    private static func script() throws -> [PerformXYOutcome] {
        let start = try pad(0, 0, .waiting, radius: 5)
        let caught = start.pointer(point(3, 3))
        let caughtPad = try #require(move(of: caught)).pad
        let adjusted = try caughtPad.adjusting(.x, by: 4)
        let next = try #require(move(of: adjusted)).pad
        return [start.pointer(point(60, 60)), caught, adjusted, try next.entering(x: nil, y: 99)]
    }

    @Test
    func aScriptEndsAtTheHandTypedFinalPosition() throws {
        let outcomes = try Self.script()
        let last = try #require(outcomes.last)
        Self.expectMove(last, to: Self.point(7, 50), nil, .aboveRange)
    }

    @Test
    func outcomeCasesCoverAMoveAndAHold() throws {
        func label(_ outcome: PerformXYOutcome) -> String {
            switch outcome {
            case .moved: "moved"
            case .held: "held"
            }
        }
        let waiting = try Self.pad(0, 0, .waiting)
        #expect(label(waiting.pointer(Self.point(1, 1))) == "moved")
        #expect(label(waiting.pointer(Self.point(50, 1))) == "held")
    }

    // MARK: - Source scan

    static func containsBytes(_ needle: String, in haystack: String) -> Bool {
        let wanted = Array(needle.utf8)
        let bytes = Array(haystack.utf8)
        guard !wanted.isEmpty, wanted.count <= bytes.count else { return false }
        let last = bytes.count - wanted.count
        for start in 0...last {
            var matched = true
            for offset in 0..<wanted.count where bytes[start + offset] != wanted[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Views/Workspace/Perform/XY",
            "../../Sources/FluxKlang/Shared/Views/Workspace/Perform/XY"
        ]
        let marker = "PerformXYPad.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Texts the production files must not contain, even in a comment. Each is joined from pieces, so that no single
    /// literal in this list spells it.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["import", " "].joined(), ["Da", "te("].joined(), ["Cl", "ock"].joined(), ["Ta", "sk"].joined(),
            ["Dispatch", "Queue"].joined(), ["defa", "ult:"].joined(), ["Dou", "ble"].joined(),
            ["Flo", "at"].joined(), ["try", "!"].joined(), ["mutat", "ing"].joined(), ["static", " var"].joined(),
            ["static", " func =="].joined()
        ]
    }

    /// Looks for each text of `forbiddenSourceWords()` in the three production files over their raw bytes, so a
    /// text in a comment is found too and an API the list does not name is not. Skipped when the sources are not
    /// next to the tests.
    @Test(.enabled(if: Self.sourcesAreReachable, "the pad sources are not next to the tests"))
    func theThreeProductionFilesContainNoForbiddenText() throws {
        let directory = try #require(Self.sourceDirectory(), "the pad sources are not next to the tests")
        let names = ["PerformXYOutcome.swift", "PerformXYPad.swift", "PerformXYRefusal.swift"]
        var hits: [String] = []
        var scanned = 0
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            scanned += 1
            for word in Self.forbiddenSourceWords() where Self.containsBytes(word, in: text) {
                hits.append("\(name): \(word)")
            }
        }
        #expect(scanned == 3)
        #expect(hits.isEmpty)
    }
}
