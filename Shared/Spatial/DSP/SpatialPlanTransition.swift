//
//  SpatialPlanTransition.swift
//  FluxKlang
//
//  ID-aligned plan state for the offline spatial block mixer (#115 SM2).
//

/// A plan row's identity: the source and the channel index within that source.
struct SpatialMixerRowKey: Hashable, Sendable {
    let source: SpatialSourceID
    let channel: Int
}

/// The mixer's gain tables and ramp state, aligned by ID and never by position.
///
/// A gain cell is keyed by (source, channel in that source, speaker). The union
/// tables hold the new plan's rows and speakers in the new plan's order, then
/// the old plan's rows and speakers that the new plan lacks, in the old order.
/// `from` is the old gain where the old plan has both the row and the speaker,
/// else 0; `to` is the new gain where the new plan has both, else 0. So a key
/// present on one side only ramps to or from 0 and every effective gain stays
/// within `min(from, to)...max(from, to)`.
///
/// All storage is allocated in `init`; `commit` and `advance` only write in place.
struct SpatialPlanTransition {
    let rowCapacity: Int
    let speakerCapacity: Int
    /// The target plan; the old plan while a ramp runs is not retained (the tables hold it).
    private(set) var plan: SpatialRenderPlan
    private(set) var rampFrames = 0
    private(set) var rampProgress = 0
    private(set) var rowCount = 0
    private(set) var speakerCount = 0
    private(set) var activeRowCount = 0
    private(set) var activeSpeakerCount = 0
    private(set) var rowSources: [SpatialSourceID] = []
    private(set) var rowChannels: [Int] = []
    private(set) var speakerIDs: [SpeakerID] = []
    private(set) var ringSlots: [Int]
    private(set) var fromDelays: [Int]
    private(set) var toDelays: [Int]
    private var fromGains: [Float]
    private var toGains: [Float]
    private var scratch: SpatialTransitionScratch

    init(rowCapacity: Int, speakerCapacity: Int, plan: SpatialRenderPlan) {
        self.rowCapacity = rowCapacity
        self.speakerCapacity = speakerCapacity
        self.plan = plan
        rowSources.reserveCapacity(rowCapacity)
        rowChannels.reserveCapacity(rowCapacity)
        speakerIDs.reserveCapacity(speakerCapacity)
        ringSlots = [Int](repeating: 0, count: speakerCapacity)
        fromDelays = [Int](repeating: 0, count: speakerCapacity)
        toDelays = [Int](repeating: 0, count: speakerCapacity)
        fromGains = [Float](repeating: 0, count: rowCapacity * speakerCapacity)
        toGains = [Float](repeating: 0, count: rowCapacity * speakerCapacity)
        scratch = SpatialTransitionScratch(rowCapacity: rowCapacity, speakerCapacity: speakerCapacity)
    }

    var isRamping: Bool { rampProgress < rampFrames }

    /// The ramp fraction at `offset` frames into the current block: 1 when idle or past the end.
    func fraction(at offset: Int) -> Double {
        guard isRamping else { return 1 }
        let position = rampProgress + offset
        return position >= rampFrames ? 1 : Double(position) / Double(rampFrames)
    }

    /// The effective Float gain of a union cell, always within its two endpoints.
    func gain(row: Int, speaker: Int, fraction: Double) -> Float {
        let index = row * speakerCapacity + speaker
        let target = toGains[index]
        guard fraction < 1 else { return target }
        let start = fromGains[index]
        guard start != target else { return target }
        let value = Float(Double(start) + (Double(target) - Double(start)) * fraction)
        return min(max(value, min(start, target)), max(start, target))
    }

    /// Advances the ramp by `frames` (overflow-checked) and drops the old-only
    /// rows and speakers once the ramp is complete.
    mutating func advance(frames: Int) {
        guard isRamping else { return }
        let (sum, overflow) = rampProgress.addingReportingOverflow(frames)
        rampProgress = overflow ? rampFrames : min(sum, rampFrames)
        guard !isRamping else { return }
        rowCount = activeRowCount
        speakerCount = activeSpeakerCount
        rowSources.removeSubrange(activeRowCount...)
        rowChannels.removeSubrange(activeRowCount...)
        speakerIDs.removeSubrange(activeSpeakerCount...)
    }

    /// Installs `newPlan`, which the caller has validated against the limits, so this cannot fail.
    /// `rampFrames == 0` replaces the tables at once; otherwise the caller guarantees no ramp is
    /// running, so the tables hold exactly the current plan (the old side of the new ramp).
    mutating func commit(_ newPlan: SpatialRenderPlan, rampFrames ramp: Int, delayLines: inout SpatialDelayLines) {
        let keepOld = ramp > 0
        let unionRows = alignRows(newPlan, keepOld: keepOld)
        let unionSpeakers = alignSpeakers(newPlan, keepOld: keepOld, delayLines: &delayLines)
        rebuildRowTable(newPlan, unionRows: unionRows)
        rebuildSpeakerTable(newPlan, unionSpeakers: unionSpeakers, keepOld: keepOld)
        fillGains(newPlan, unionRows: unionRows, unionSpeakers: unionSpeakers, keepOld: keepOld)
        plan = newPlan
        rampFrames = ramp
        rampProgress = 0
        rowCount = unionRows
        speakerCount = unionSpeakers
        activeRowCount = newPlan.rowCount
        activeSpeakerCount = newPlan.speakerCount
    }

    /// Ruling 6: a gain converted to Float is clamped to 0...1; a non-finite gain becomes 0 (never a boost).
    static func floatGain(_ value: Double) -> Float {
        guard value.isFinite else { return 0 }
        return Float(min(max(value, 0), 1))
    }

    /// Per row: the number of earlier rows with the same source.
    private static func channelIndices(of sources: [SpatialSourceID], into channels: inout [Int]) {
        for row in 0..<sources.count {
            var earlier = 0
            for other in 0..<row where sources[other] == sources[row] { earlier += 1 }
            channels[row] = earlier
        }
    }

    /// Fills `rowOld` for the union rows (-1 where the old plan lacks the row); returns the union size.
    private mutating func alignRows(_ newPlan: SpatialRenderPlan, keepOld: Bool) -> Int {
        let newRows = newPlan.rowCount
        Self.channelIndices(of: newPlan.rowSources, into: &scratch.newChannels)
        for row in 0..<newRows { scratch.rowOld[row] = -1 }
        guard keepOld else { return newRows }
        let oldRows = plan.rowCount
        Self.channelIndices(of: plan.rowSources, into: &scratch.oldChannels)
        for row in 0..<oldRows { scratch.rowMatched[row] = false }
        for row in 0..<newRows {
            for old in 0..<oldRows where !scratch.rowMatched[old] && plan.rowSources[old] == newPlan.rowSources[row]
                && scratch.oldChannels[old] == scratch.newChannels[row] {
                scratch.rowOld[row] = old
                scratch.rowMatched[old] = true
                break
            }
        }
        var union = newRows
        for old in 0..<oldRows where !scratch.rowMatched[old] {
            scratch.rowOld[union] = old
            union += 1
        }
        return union
    }

    /// Matches speakers by ID, assigns rings (reusing a matched speaker's ring, zeroing any other),
    /// and fills `speakerOld`/`newRing` for the union speakers; returns the union size.
    private mutating func alignSpeakers(
        _ newPlan: SpatialRenderPlan, keepOld: Bool, delayLines: inout SpatialDelayLines
    ) -> Int {
        let newCount = newPlan.speakerCount
        let currentCount = speakerCount
        for ring in 0..<speakerCapacity { scratch.ringTaken[ring] = false }
        for current in 0..<currentCount {
            scratch.speakerMatched[current] = false
            scratch.ringTaken[ringSlots[current]] = keepOld
        }
        for speaker in 0..<newCount {
            var found = -1
            for current in 0..<currentCount where speakerIDs[current] == newPlan.speakerIDs[speaker] {
                found = current
                break
            }
            scratch.speakerOld[speaker] = keepOld ? found : -1
            guard found >= 0 else {
                scratch.newRing[speaker] = -1
                continue
            }
            scratch.speakerMatched[found] = true
            scratch.newRing[speaker] = ringSlots[found]
            scratch.ringTaken[ringSlots[found]] = true
        }
        for speaker in 0..<newCount where scratch.newRing[speaker] < 0 {
            let ring = scratch.ringTaken.firstIndex(of: false) ?? 0
            scratch.ringTaken[ring] = true
            scratch.newRing[speaker] = ring
            delayLines.clear(ring: ring)
        }
        guard keepOld else { return newCount }
        var union = newCount
        for current in 0..<currentCount where !scratch.speakerMatched[current] {
            scratch.speakerOld[union] = current
            scratch.newRing[union] = ringSlots[current]
            union += 1
        }
        return union
    }

    private mutating func rebuildRowTable(_ newPlan: SpatialRenderPlan, unionRows: Int) {
        rowSources.removeAll(keepingCapacity: true)
        rowChannels.removeAll(keepingCapacity: true)
        for row in 0..<newPlan.rowCount {
            rowSources.append(newPlan.rowSources[row])
            rowChannels.append(scratch.newChannels[row])
        }
        for row in newPlan.rowCount..<unionRows {
            rowSources.append(plan.rowSources[scratch.rowOld[row]])
            rowChannels.append(scratch.oldChannels[scratch.rowOld[row]])
        }
    }

    private mutating func rebuildSpeakerTable(_ newPlan: SpatialRenderPlan, unionSpeakers: Int, keepOld: Bool) {
        speakerIDs.removeAll(keepingCapacity: true)
        for speaker in 0..<unionSpeakers {
            let old = scratch.speakerOld[speaker]
            let isNew = speaker < newPlan.speakerCount
            speakerIDs.append(isNew ? newPlan.speakerIDs[speaker] : plan.speakerIDs[old])
            ringSlots[speaker] = scratch.newRing[speaker]
            let target = isNew ? newPlan.delayFrames[speaker] : plan.delayFrames[old]
            toDelays[speaker] = target
            fromDelays[speaker] = keepOld && old >= 0 ? plan.delayFrames[old] : target
        }
    }

    private mutating func fillGains(
        _ newPlan: SpatialRenderPlan, unionRows: Int, unionSpeakers: Int, keepOld: Bool
    ) {
        for row in 0..<unionRows {
            for speaker in 0..<unionSpeakers {
                let index = row * speakerCapacity + speaker
                var target: Float = 0
                if row < newPlan.rowCount, speaker < newPlan.speakerCount {
                    target = Self.floatGain(newPlan.gain(row: row, speaker: speaker))
                }
                toGains[index] = target
                fromGains[index] = keepOld ? oldGain(row: scratch.rowOld[row], speaker: scratch.speakerOld[speaker])
                    : target
            }
        }
    }

    private func oldGain(row: Int, speaker: Int) -> Float {
        guard row >= 0, speaker >= 0 else { return 0 }
        return Self.floatGain(plan.gain(row: row, speaker: speaker))
    }
}

/// Preallocated work arrays for `SpatialPlanTransition.commit`, so a commit allocates nothing.
private struct SpatialTransitionScratch {
    var newChannels: [Int]
    var oldChannels: [Int]
    var rowOld: [Int]
    var rowMatched: [Bool]
    var speakerOld: [Int]
    var speakerMatched: [Bool]
    var newRing: [Int]
    var ringTaken: [Bool]

    init(rowCapacity: Int, speakerCapacity: Int) {
        newChannels = [Int](repeating: 0, count: rowCapacity)
        oldChannels = [Int](repeating: 0, count: rowCapacity)
        rowOld = [Int](repeating: -1, count: rowCapacity)
        rowMatched = [Bool](repeating: false, count: rowCapacity)
        speakerOld = [Int](repeating: -1, count: speakerCapacity)
        speakerMatched = [Bool](repeating: false, count: speakerCapacity)
        newRing = [Int](repeating: 0, count: speakerCapacity)
        ringTaken = [Bool](repeating: false, count: speakerCapacity)
    }
}
