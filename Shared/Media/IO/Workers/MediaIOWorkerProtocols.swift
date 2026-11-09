//
//  MediaIOWorkerProtocols.swift
//  FluxKlang
//
//  The reader and writer worker protocols (#109 IO2, media-contract.md §8.2,
//  §8.3). Workers run off the render thread and carry counts and positions
//  only; moving samples into a `MediaBlockPool` block is the adapter's job
//  (IO1 `copyIn` / `withSamples`). The scripted fakes in this directory are the
//  only conforming types of this slice and use no file, thread or clock.
//

/// A reader that fills the leased block named by a request.
///
/// Contract: `read` never blocks. It is called again with the SAME request while it returns `.pending`.
/// `.ready(result)` means the first `result.frames` frames of the request are stored in the leased block
/// (`0 <= result.frames <= request.frames`; the fill pump refuses anything else). A worker never grows or
/// allocates a block and is never called from the render thread. `mutating` lets value-type fakes and
/// class-backed real workers conform.
protocol MediaReaderWorker: Sendable {
    mutating func read(_ request: MediaReadRequest) throws(MediaReadFault) -> MediaReadPoll
}

/// A writer that takes frames from the leased block named by a request and seals one file.
///
/// Contract: `write` returns `.accepted(frames: a)`: the first `a` frames of the request were taken. A short accept
/// means the caller must resubmit the rest, and the resubmitted request names the rest by `startFrame` and
/// `blockOffset` (the frames already accepted for the block), so nothing is dropped or written twice. The request
/// cannot know the block's used frames: a writer must also refuse blockOffset + frames above the block's usedFrames.
/// `finish` seals the file and reports how many accepted frames are durable. Never called from the render thread.
protocol MediaWriterWorker: Sendable {
    mutating func write(_ request: MediaWriteRequest) throws(MediaWriteFault) -> MediaWritePoll
    mutating func finish() throws(MediaWriteFault) -> MediaWriteFinish
}
