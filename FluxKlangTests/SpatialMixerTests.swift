import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("SpatialMixerTests")
struct SpatialMixerTests {
    struct Source {
        let name: String
        let horizontal: Double
        let vertical: Double
        let channels: Int
    }

    struct Delay {
        let speaker: Int
        let frames: Int
    }

    struct Block {
        let columns: [[Float]]
        let result: SpatialMixerResult
    }

    struct State: Equatable {
        let plan: SpatialRenderPlan
        let ramp: Int
        let progress: Int
        let write: Int
        let transitioning: Bool
        let rows: Int
        let columns: Int
        let keys: [String]
        let speakers: [String]
    }

    static func snapshot(_ mixer: borrowing SpatialBlockMixer) -> State {
        State(
            plan: mixer.activePlan, ramp: mixer.rampFrames, progress: mixer.rampProgress,
            write: mixer.delayWritePosition, transitioning: mixer.isTransitioning,
            rows: mixer.inputRowCount, columns: mixer.outputSpeakerCount,
            keys: mixer.inputRowKeys.map { "\($0.source.rawValue)#\($0.channel)" },
            speakers: mixer.outputSpeakerIDs.map(\.rawValue)
        )
    }

    static func source(_ name: String, _ horizontal: Double, _ vertical: Double = 0, channels: Int = 1) -> Source {
        Source(name: name, horizontal: horizontal, vertical: vertical, channels: channels)
    }

    static func speakerName(_ index: Int) -> String { "spk.\(index)" }

    /// Speakers `ids` on a line; the position follows the number, never the list position.
    static func layout(_ ids: [Int], of total: Int) throws -> SpatialLayout {
        let speakers = try ids.map { index in
            let horizontal = total <= 1 ? 0 : -1 + 2 * Double(index) / Double(total - 1)
            return try SpatialSpeaker(
                id: SpeakerID(speakerName(index)),
                position: NeutralPoint(x: horizontal, y: index % 2 == 0 ? 0.5 : -0.5),
                route: RouteID("rte." + speakerName(index))
            )
        }
        return try SpatialLayout(speakers: speakers)
    }

    static func plan(
        _ ids: [Int], of total: Int, _ sources: [Source], masks: [SpatialOutputMask] = [],
        renormalize: Bool = false, delays: [Delay] = [], lost: [Int] = [], rate: Double = 48_000
    ) throws -> SpatialRenderPlan {
        let entries = try delays.map {
            try SpeakerCalibration(speaker: SpeakerID(speakerName($0.speaker)), delaySeconds: Double($0.frames) / rate)
        }
        return try plan(
            ids, of: total, sources, masks: masks, renormalize: renormalize,
            calibration: SpatialCalibrationSet(generation: 1, entries: entries), lost: lost, rate: rate
        )
    }

    static func plan(
        _ ids: [Int], of total: Int, _ sources: [Source], masks: [SpatialOutputMask] = [],
        renormalize: Bool = false, calibration: SpatialCalibrationSet, lost: [Int] = [], rate: Double = 48_000
    ) throws -> SpatialRenderPlan {
        let placements = try sources.map {
            try SpatialSourcePlacement(
                sourceID: SpatialSourceID($0.name), position: NeutralPoint(x: $0.horizontal, y: $0.vertical),
                channelCount: $0.channels
            )
        }
        let routes = try Set(ids.filter { !lost.contains($0) }.map { try RouteID("rte." + speakerName($0)) })
        return try SpatialRenderer.plan(SpatialRenderRequest(
            layout: layout(ids, of: total), placements: placements,
            masks: SpatialMaskSet(masks: masks, renormalizeSurvivors: renormalize), calibration: calibration,
            availableRoutes: lost.isEmpty ? nil : routes, sampleRate: rate
        ))
    }

    static func mute(_ index: Int) throws -> SpatialOutputMask {
        SpatialOutputMask(speaker: try SpeakerID(speakerName(index)), state: .muted)
    }

    static func solo(_ index: Int) throws -> SpatialOutputMask {
        SpatialOutputMask(speaker: try SpeakerID(speakerName(index)), state: .soloed)
    }

    static func limits(
        maxFrames: Int = 64, rate: Double = 48_000, rows: Int = 8, speakers: Int = 8
    ) throws -> SpatialMixerLimits {
        try SpatialMixerLimits.make(maxFrames: maxFrames, sampleRate: rate, maxRows: rows, maxSpeakers: speakers)
    }

    static func mixer(
        _ plan: SpatialRenderPlan, maxFrames: Int = 64, rate: Double = 48_000, rows: Int = 8, speakers: Int = 8
    ) throws -> SpatialBlockMixer {
        try SpatialBlockMixer(
            limits: limits(maxFrames: maxFrames, rate: rate, rows: rows, speakers: speakers), initial: plan
        )
    }

    /// The Float gain of a key in `plan`, or 0 where the plan lacks the source, channel or speaker.
    static func gain(_ plan: SpatialRenderPlan, _ source: String, _ channel: Int, _ speaker: Int) -> Float {
        guard let column = plan.speakerIDs.firstIndex(where: { $0.rawValue == speakerName(speaker) }) else { return 0 }
        var seen = 0
        for row in plan.rowSources.indices where plan.rowSources[row].rawValue == source {
            if seen == channel { return Float(plan.gain(row: row, speaker: column)) }
            seen += 1
        }
        return 0
    }

    static let sentinel: Float = 7

    /// One block: row `r` of `rows` is placed at `r * maxFrames`; columns follow the mixer's output order.
    static func run(_ mixer: inout SpatialBlockMixer, _ rows: [[Float]], frames: Int) -> Block {
        let stride = mixer.limits.maxFrames
        var input = [Float](repeating: 0, count: mixer.inputRowCount * stride)
        for (row, samples) in rows.enumerated() where row < mixer.inputRowCount {
            for (frame, sample) in samples.enumerated() where frame < stride { input[row * stride + frame] = sample }
        }
        let speakers = mixer.outputSpeakerCount
        var output = [Float](repeating: sentinel, count: speakers * stride)
        let result = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                mixer.process(frames: frames, input: source, output: destination)
            }
        }
        let columns = (0..<speakers).map { speaker in
            Array(output[(speaker * stride)..<(speaker * stride + max(0, min(frames, stride)))])
        }
        return Block(columns: columns, result: result)
    }

    static func constant(_ value: Float, _ count: Int) -> [Float] { [Float](repeating: value, count: count) }

    static func counting(_ count: Int) -> [Float] { (0..<count).map { Float($0 + 1) } }

    static func impulse(at frame: Int, _ value: Float = 1, count: Int) -> [Float] {
        var samples = constant(0, count)
        samples[frame] = value
        return samples
    }

    /// A deterministic per-key test signal.
    static func signal(_ key: SpatialMixerRowKey, _ frame: Int) -> Float {
        let salt = key.source.rawValue.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 1_009 } + key.channel * 7
        return Float((frame &* 13 &+ salt) % 23) / 23 - 0.3
    }

    /// Streams `total` frames in blocks of `block`, feeding each key its own signal and
    /// collecting every speaker's samples by ID; a column that no longer exists reads as 0.
    static func stream(_ mixer: inout SpatialBlockMixer, total: Int, block: Int) -> [String: [Float]] {
        var collected: [String: [Float]] = [:]
        var start = 0
        while start < total {
            let frames = min(block, total - start)
            let rows = mixer.inputRowKeys.map { key in (0..<frames).map { signal(key, start + $0) } }
            let ids = mixer.outputSpeakerIDs
            let result = run(&mixer, rows, frames: frames)
            for (index, id) in ids.enumerated() {
                var samples = collected[id.rawValue] ?? [Float](repeating: 0, count: total)
                let column = index < result.columns.count ? result.columns[index] : []
                for (frame, value) in column.prefix(frames).enumerated() { samples[start + frame] = value }
                collected[id.rawValue] = samples
            }
            start += frames
        }
        return collected
    }

    // MARK: Limits

    @Test func limitsAcceptEveryFrameBoundAndRefuseTheNextValue() throws {
        #expect(try Self.limits(maxFrames: 1).maxFrames == 1)
        #expect(try Self.limits(maxFrames: 8_192).maxFrames == 8_192)
        for bad in [0, -1, 8_193] {
            #expect(throws: SpatialMixerRefusal.invalidLimits) { try Self.limits(maxFrames: bad) }
        }
    }

    @Test func limitsAcceptEverySampleRateBoundAndRefuseTheNextValue() throws {
        #expect(try Self.limits(rate: 8_000).sampleRate == 8_000)
        #expect(try Self.limits(rate: 384_000).sampleRate == 384_000)
        for bad in [7_999.9, 384_000.1, Double.nan, Double.infinity, -48_000] {
            #expect(throws: SpatialMixerRefusal.invalidLimits) { try Self.limits(rate: bad) }
        }
    }

    @Test func limitsAcceptEverySpeakerBoundAndRefuseTheNextValue() throws {
        #expect(try Self.limits(speakers: 1).maxSpeakers == 1)
        #expect(try Self.limits(speakers: 64).maxSpeakers == 64)
        for bad in [0, -1, 65] {
            #expect(throws: SpatialMixerRefusal.invalidLimits) { try Self.limits(speakers: bad) }
        }
    }

    @Test func limitsAcceptEveryRowBoundAndRefuseTheNextValue() throws {
        #expect(try Self.limits(rows: 1).maxRows == 1)
        #expect(try Self.limits(rows: 128).maxRows == 128)
        for bad in [0, -1, 129] {
            #expect(throws: SpatialMixerRefusal.invalidLimits) { try Self.limits(rows: bad) }
        }
    }

    @Test func delayCapacityIsTheCeilingOfFiftyMilliseconds() throws {
        #expect(try Self.limits(rate: 8_000).delayCapacity == 400)
        #expect(try Self.limits(rate: 8_010).delayCapacity == 401)
        #expect(try Self.limits(rate: 44_100).delayCapacity == 2_205)
        #expect(try Self.limits(rate: 48_000).delayCapacity == 2_400)
        #expect(try Self.limits(rate: 384_000).delayCapacity == 19_200)
    }

    // MARK: Construction

    @Test func initRefusesAPlanLargerThanTheLimitsAndAcceptsExactlyTheLimit() throws {
        let three = try Self.plan([0, 1], of: 2, [Self.source("a", 0), Self.source("b", 0.5), Self.source("c", -0.5)])
        #expect(throws: SpatialMixerRefusal.planTooLarge) { _ = try Self.mixer(three, rows: 2) }
        _ = try Self.mixer(three, rows: 3)
        let wide = try Self.plan([0, 1, 2], of: 3, [Self.source("a", 0)])
        #expect(throws: SpatialMixerRefusal.planTooLarge) { _ = try Self.mixer(wide, speakers: 2) }
        _ = try Self.mixer(wide, speakers: 3)
    }

    @Test func initExposesTheInitialPlanAndAnIdleState() throws {
        let plan = try Self.plan([0, 1], of: 2, [Self.source("a", 0), Self.source("b", 0.5, channels: 2)])
        let mixer = try Self.mixer(plan)
        let state = Self.snapshot(mixer)
        #expect(state == State(plan: plan, ramp: 0, progress: 0, write: 0, transitioning: false, rows: 3, columns: 2,
                               keys: ["a#0", "b#0", "b#1"], speakers: ["spk.0", "spk.1"]))
        #expect(!state.transitioning)
    }

    @Test func anEmptyPlanIsAcceptedAndProcessesEmptyBuffers() throws {
        let silent = try Self.plan([0, 1], of: 2, [])
        var mixer = try Self.mixer(silent)
        let state = Self.snapshot(mixer)
        #expect(state.keys.isEmpty && state.speakers == ["spk.0", "spk.1"])
        let block = Self.run(&mixer, [], frames: 4)
        #expect(block.result == .processed(sanitizedSamples: 0))
        #expect(block.columns == [[0, 0, 0, 0], [0, 0, 0, 0]])
        var bare = try Self.mixer(SpatialRenderer.plan(SpatialRenderRequest(
            layout: SpatialLayout(speakers: []), placements: [])))
        let nothing = bare.process(frames: 3, input: UnsafeBufferPointer(start: nil, count: 0),
                                   output: UnsafeMutableBufferPointer(start: nil, count: 0))
        #expect(nothing == .processed(sanitizedSamples: 0))
        #expect(bare.process(frames: -1, input: UnsafeBufferPointer(start: nil, count: 0),
                             output: UnsafeMutableBufferPointer(start: nil, count: 0)) == .refused(.invalidFrames(-1)))
    }
}
