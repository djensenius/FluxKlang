//
//  CaptureDrainPump+Write.swift
//  FluxKlang
//
//  The non-mutating checks of `CaptureDrainPump` and its summary builder
//  (#109 WDP1). Each check runs before the pump assigns anything, in the
//  documented order; a throw here therefore leaves the pump untouched.
//

/// The ticket in flight and the head block it was issued from.
struct CaptureDrainInFlight: Equatable, Sendable {
    let ticket: CaptureDrainTicket
    let block: CaptureDrainBlock
}

extension CaptureDrainPump {
    /// Why `nextWrite` has nothing to issue, in the order stopped, finished, in flight; nil when it may issue.
    var idleReason: CaptureDrainIdle? {
        switch state {
        case .stopped: .stopped
        case .finished: .finished
        case .running: inFlight == nil ? nil : .inFlight
        }
    }

    /// The reason of a latched fault, or nil when none latched.
    var latchedReason: RuntimeCaptureStopReason? {
        latchedFault.map { MediaIOFaultMapping.captureStopReason(for: $0) }
    }

    /// Order: finished, request span (frames range, `Int64` overflow), lease already queued.
    func checkEnqueue(lease: MediaBlockLease, frames: Int) throws(CaptureDrainRefusal) {
        if case .finished = state { throw .alreadyFinished }
        do throws(MediaIORequestRefusal) {
            _ = try MediaWriteRequest.make(lease: lease, startFrame: streamEnd, frames: frames)
        } catch {
            throw .request(error)
        }
        guard !held.contains(lease) else { throw .leaseAlreadyQueued }
    }

    /// Order: finished, frames range, `Int64` overflow of the stream end.
    func checkPad(frames: Int) throws(CaptureDrainRefusal) {
        if case .finished = state { throw .alreadyFinished }
        let maximum = CaptureDrainLimits.maximumPaddingFrames
        guard (1...maximum).contains(frames) else {
            throw .paddingFramesOutOfRange(frames: frames, maximum: maximum)
        }
        guard !streamEnd.addingReportingOverflow(Int64(frames)).overflow else {
            throw .request(.frameOverflow(startFrame: streamEnd, frames: frames))
        }
    }

    /// The remainder of the head block as a validated request: it names the rest by the stream position and the
    /// block offset of the frames already accepted.
    func makeRequest(for block: CaptureDrainBlock) throws(CaptureDrainRefusal) -> MediaWriteRequest {
        do throws(MediaIORequestRefusal) {
            return try MediaWriteRequest.make(lease: block.lease, startFrame: block.startFrame + Int64(headWritten),
                                              frames: block.frames - headWritten, blockOffset: headWritten)
        } catch {
            throw .request(error)
        }
    }

    /// The ticket in flight when `id` names it. The head block exists while a ticket is in flight: a ticket is
    /// issued from the head and cleared before the head changes.
    func checkInFlight(_ id: UInt64) throws(CaptureDrainRefusal) -> CaptureDrainInFlight {
        guard let ticket = inFlight, ticket.id == id, let block = ring[headIndex] else {
            throw .unknownTicket(id)
        }
        return CaptureDrainInFlight(ticket: ticket, block: block)
    }

    /// Order: accepted outside `1...requested`, then the `Int64` overflow of the accepted total.
    func checkAccepted(_ accepted: Int, for ticket: CaptureDrainTicket) throws(CaptureDrainRefusal) {
        let requested = ticket.request.frames
        guard (1...requested).contains(accepted) else {
            throw .acceptedFramesOutOfRange(accepted: accepted, requested: requested)
        }
        guard !acceptedFrames.addingReportingOverflow(Int64(accepted)).overflow else {
            throw .acceptedFramesOverflow
        }
    }

    /// Order: finished, a ticket in flight, a running pump with queued blocks.
    func checkFinish() throws(CaptureDrainRefusal) {
        if case .finished = state { throw .alreadyFinished }
        guard inFlight == nil else { throw .writeInFlight }
        if case .running = state, pendingBlocks > 0 {
            throw .blocksStillPending(count: pendingBlocks)
        }
    }

    func makeSummary(sealing: CaptureDrainSealing, stopReason: RuntimeCaptureStopReason?) -> CaptureDrainSummary {
        CaptureDrainSummary(startFrame: startFrame, streamFrames: streamEnd - startFrame,
                            acceptedFrames: acceptedFrames, paddedFrames: paddedFrames,
                            unwrittenFrames: unwrittenFrames, reclaimedFrames: reclaimedFrames,
                            sealing: sealing, stopReason: stopReason)
    }
}
