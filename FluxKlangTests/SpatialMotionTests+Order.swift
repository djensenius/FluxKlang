//
//  SpatialMotionTests+Order.swift
//  FluxKlangTests
//
//  The pinned refusal order of `SpatialMotionPath.make`: every fixture holds both defects of the pair it tests, so
//  swapping the two checks changes the refusal. Also a scan of the three production files for forbidden text.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialMotionTests {
    @Test func aFrameOutOfRangeIsReportedBeforeANonFiniteCoordinateOfTheSameWaypoint() {
        let both: SpatialMotionRefusal? = Self.refusal([Self.pin(-1, Double.nan), Self.pin(1, 0)])
        let expected: SpatialMotionRefusal? = .frameOutOfRange(index: 0)
        #expect(both == expected)
    }

    @Test func aNonFiniteCoordinateIsReportedBeforeAnOutOfRangeCoordinateOfTheSameWaypoint() {
        let both: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 2.0, Double.nan), Self.pin(1, 0)])
        let expected: SpatialMotionRefusal? = .nonFiniteCoordinate(index: 0)
        #expect(both == expected)
    }

    @Test func anOutOfRangeCoordinateIsReportedBeforeANonIncreasingFrameOfTheSameWaypoint() {
        let both: SpatialMotionRefusal? = Self.refusal([Self.pin(5, 0), Self.pin(3, 2.0)])
        let expected: SpatialMotionRefusal? = .coordinateOutOfRange(index: 1)
        #expect(both == expected)
    }

    @Test func aFrameOutOfRangeIsReportedBeforeANonIncreasingFrameOfTheSameWaypoint() {
        let both: SpatialMotionRefusal? = Self.refusal([Self.pin(5, 0), Self.pin(Int64.min, 0)])
        let expected: SpatialMotionRefusal? = .frameOutOfRange(index: 1)
        #expect(both == expected)
    }

    @Test func aSingleWaypointWithABadFrameIsReportedAsTooFewWaypoints() {
        let both: SpatialMotionRefusal? = Self.refusal([Self.pin(-1, 0)])
        let expected: SpatialMotionRefusal? = .tooFewWaypoints(1)
        #expect(both == expected)
    }

    @Test func tooManyWaypointsWithABadFirstFrameAreReportedAsTooManyBeforeAnyWaypointIsChecked() {
        var waypoints = Self.ramp(count: 257)
        waypoints[0] = Self.pin(-1, 0)
        let both: SpatialMotionRefusal? = Self.refusal(waypoints)
        let expected: SpatialMotionRefusal? = .tooManyWaypoints(257)
        #expect(both == expected)
    }

    @Test func aNonFiniteOrOutOfRangeCoordinateOfAnEarlierWaypointIsReportedBeforeADefectOfALaterOne() {
        let nonFiniteFirst: SpatialMotionRefusal? = Self.refusal([Self.pin(0, Double.nan), Self.pin(-1, 0)])
        let rangeFirst: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 2.0), Self.pin(1, Double.nan)])
        let expectedNonFinite: SpatialMotionRefusal? = .nonFiniteCoordinate(index: 0)
        let expectedRange: SpatialMotionRefusal? = .coordinateOutOfRange(index: 0)
        #expect(nonFiniteFirst == expectedNonFinite)
        #expect(rangeFirst == expectedRange)
    }

    // MARK: Source scan

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Spatial/Motion",
            "../../Sources/FluxKlang/Shared/Spatial/Motion"
        ]
        let marker = "SpatialMotionPath.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Texts the production files must not contain, even in a comment. Each is joined from pieces, so that no single
    /// literal in this list spells it.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["imp", "ort "].joined(), ["Ta", "sk"].joined(), ["Cl", "ock"].joined(), ["Da", "te"].joined(),
            ["Dispatch", "Queue"].joined(), ["Swift", "UI"].joined(), ["defa", "ult:"].joined(),
            ["mut", "ating"].joined(), ["static", " var"].joined(), ["nonisolated", "(unsafe)"].joined(),
            ["adding", "Product"].joined(), ["Spatial", "Gain"].joined(), ["SpatialSource", "Placement"].joined()
        ]
    }

    private static let operatorCharacters: Set<Character> = [
        "=", "<", ">", "+", "-", "*", "/", "!", "&", "|", "%", "^", "~"
    ]

    /// Reads the three production files as text and looks for each forbidden text and for a static function whose name
    /// is an operator. Skipped when the sources are not next to the tests.
    @Test(.enabled(if: Self.sourcesAreReachable, "the motion sources are not next to the tests"))
    func theThreeProductionFilesContainNoForbiddenTextAndNoHandWrittenOperator() throws {
        let directory = try #require(Self.sourceDirectory(), "the motion sources are not next to the tests")
        let names = ["SpatialMotionPath.swift", "SpatialMotionRefusal.swift", "SpatialMotionSampling.swift"]
        var hits: [String] = []
        var scanned = 0
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            scanned += 1
            for word in Self.forbiddenSourceWords() where text.contains(word) {
                hits.append("\(name): \(word)")
            }
            for piece in text.components(separatedBy: "static func ").dropFirst() {
                if let next = piece.first, Self.operatorCharacters.contains(next) {
                    hits.append("\(name): operator")
                }
            }
        }
        #expect(scanned == 3)
        #expect(hits.isEmpty)
    }
}
