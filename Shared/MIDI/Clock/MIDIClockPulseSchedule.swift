//
//  MIDIClockPulseSchedule.swift
//  FluxKlang
//
//  Outgoing 24-PPQN clock pulses for one render block, placed through the
//  musical clock map. Each pulse belongs to the block containing its
//  half-up rounded frame, so consecutive blocks never drop or repeat a pulse.
//  Not for the render thread: each call allocates its result array.
//

struct MIDIClockPulseFrame: Equatable, Sendable {
    let frame: Int64
    let ticks: Int64

    var pulseIndex: Int64 { ticks / MIDIClockMath.ticksPerPulse }
}

enum MIDIClockPulseSchedule {
    static let maximumCapacity = 4_096

    /// The pulses at non-negative ticks whose frames lie in `[startFrame, startFrame + frameCount)`.
    static func pulses(in map: MusicalClockMap, startFrame: Int64, frameCount: Int64,
                       capacity: Int) throws(MIDIClockError) -> [MIDIClockPulseFrame] {
        guard (1...maximumCapacity).contains(capacity) else { throw .invalidCapacity(capacity) }
        let (endFrame, overflow) = startFrame.addingReportingOverflow(frameCount)
        guard frameCount > 0, !overflow else {
            throw .invalidBlock(startFrame: startFrame, frameCount: frameCount)
        }
        let grid = MIDIClockMath.ticksPerPulse
        let boundary: Int64
        do {
            boundary = try map.boundary(atOrAfterFrame: startFrame, grid: grid)
        } catch {
            throw .clockMap(error)
        }
        // A pulse before the exact boundary can still round up into this block. Pulses are
        // more than one frame apart at every legal tempo and rate, so one step back suffices.
        var ticks = boundary > 0 ? boundary - grid : 0
        var result: [MIDIClockPulseFrame] = []
        result.reserveCapacity(capacity)
        while true {
            let frame = try frame(of: ticks, in: map)
            guard frame < endFrame else { return result }
            if frame >= startFrame {
                guard result.count < capacity else { throw .pulseCapacityExceeded(capacity: capacity) }
                result.append(MIDIClockPulseFrame(frame: frame, ticks: ticks))
            }
            let (next, nextOverflow) = ticks.addingReportingOverflow(grid)
            guard !nextOverflow else { throw .positionOverflow }
            ticks = next
        }
    }

    private static func frame(of ticks: Int64, in map: MusicalClockMap) throws(MIDIClockError) -> Int64 {
        do {
            return try map.frame(atTicks: ticks)
        } catch {
            throw .clockMap(error)
        }
    }
}
