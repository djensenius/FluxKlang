//
//  SpatialTests.swift
//  FluxKlangTests
//

import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

struct SpatialTests {
    private let quad = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)
    ]

    // MARK: - Panner

    @Test func emptyLayoutYieldsNoGains() {
        #expect(SpatialPanner.gains(source: CGPoint(x: 0.5, y: 0.5), speakers: []).isEmpty)
    }

    @Test func centreIsEqualAcrossSymmetricLayout() {
        let gains = SpatialPanner.gains(source: CGPoint(x: 0.5, y: 0.5), speakers: quad)
        #expect(gains.count == 4)
        for gain in gains {
            #expect(abs(gain - 0.5) < 0.0001)
        }
    }

    @Test func gainsAreConstantPower() {
        let sources = [
            CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.2, y: 0.8),
            CGPoint(x: 0, y: 0), CGPoint(x: 0.9, y: 0.1)
        ]
        for source in sources {
            let gains = SpatialPanner.gains(source: source, speakers: quad)
            let power = gains.reduce(0) { $0 + $1 * $1 }
            #expect(abs(power - 1) < 0.0001)
        }
    }

    @Test func nearestSpeakerDominates() {
        let gains = SpatialPanner.gains(source: CGPoint(x: 0, y: 0), speakers: quad)
        let maxGain = gains.max() ?? 0
        #expect(gains[0] == maxGain)
        #expect(gains[0] > gains[1])
        #expect(gains[0] > gains[3])
    }

    @Test func higherRolloffSharpensTheImage() {
        let gentle = SpatialPanner.gains(source: CGPoint(x: 0.1, y: 0.1), speakers: quad, rolloff: 3)
        let steep = SpatialPanner.gains(source: CGPoint(x: 0.1, y: 0.1), speakers: quad, rolloff: 12)
        #expect(steep[0] > gentle[0])
    }

    // MARK: - Gain → dB

    @Test func unityGainMapsToZeroDecibels() {
        #expect(SpatialPanner.decibels(forGain: 1) == 0)
    }

    @Test func halfGainIsAboutMinusSixDecibels() {
        #expect(abs(SpatialPanner.decibels(forGain: 0.5) + 6.02) < 0.1)
    }

    @Test func silenceHitsTheFloor() {
        #expect(SpatialPanner.decibels(forGain: 0) == SpatialPanner.silenceFloor)
        #expect(SpatialPanner.decibels(forGain: 0.00001) == SpatialPanner.silenceFloor)
    }

    @Test func decibelsNeverExceedUnity() {
        #expect(SpatialPanner.decibels(forGain: 2) == 0)
    }

    // MARK: - Source placement

    @Test func monoSourceMapsToOnePlacement() {
        let source = SpatialSource(name: "Mono", left: .channel(3), position: CGPoint(x: 0.4, y: 0.6))
        let placements = source.channelPlacements()
        #expect(placements.count == 1)
        #expect(placements[0].channel == .channel(3))
        #expect(placements[0].point == CGPoint(x: 0.4, y: 0.6))
    }

    @Test func stereoSourceSpreadsAroundCentre() {
        let source = SpatialSource(
            name: "Stereo", mode: .stereo,
            left: .channel(5), right: .channel(11),
            position: CGPoint(x: 0.5, y: 0.5), width: 0.5
        )
        let placements = source.channelPlacements()
        #expect(placements.count == 2)
        #expect(abs(placements[0].point.x - 0.375) < 0.0001)
        #expect(abs(placements[1].point.x - 0.625) < 0.0001)
        #expect(placements[0].point.y == 0.5)
    }

    @Test func stereoModeWithoutRightFallsBackToMono() {
        let source = SpatialSource(name: "Broken", mode: .stereo, left: .channel(1))
        #expect(source.isStereo == false)
        #expect(source.channelPlacements().count == 1)
    }

    @Test func stereoSpreadClampsToBounds() {
        let source = SpatialSource(
            name: "Edge", mode: .stereo,
            left: .channel(1), right: .channel(2),
            position: CGPoint(x: 0.95, y: 0.5), width: 1
        )
        let placements = source.channelPlacements()
        #expect(placements[1].point.x <= 1)
        #expect(placements[0].point.x >= 0)
    }

    // MARK: - Speaker array

    @Test func standardQuadHasFourSpeakersInTwoPairs() {
        let array = SpeakerArray.standardQuad
        #expect(array.speakers.count == 4)
        #expect(array.pairs.count == 2)
        #expect(array.speakers.map { $0.node } == [.bus(1), .bus(2), .bus(3), .bus(4)])
    }

    @Test func speakerLookupResolvesPairMembers() {
        let array = SpeakerArray.standardQuad
        let front = array.pairs[0]
        #expect(array.speaker(front.left)?.node == .bus(1))
        #expect(array.speaker(front.right)?.node == .bus(2))
    }
}
