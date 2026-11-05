//
//  LatencyEvidence.swift
//  FluxKlang
//
//  Input latency of a take (media-contract.md §8.5): the device or OS claim and,
//  separately, a loopback measurement that must cite its evidence. Reported
//  latency is never presented as measured.
//

struct MeasuredLatency: Hashable, Sendable {
    static let maximumEvidenceBytes = 256

    let frames: Int64
    /// What the measurement was, for example the loopback run that produced it.
    let evidence: String

    init(frames: Int64, evidence: String) throws(TakeLedgerError) {
        guard frames >= 0 else { throw .negativeLatency(frames) }
        let bytes = evidence.utf8.count
        guard bytes <= Self.maximumEvidenceBytes, evidence.contains(where: { !$0.isWhitespace }) else {
            throw .invalidLatencyEvidence(bytes: bytes)
        }
        self.frames = frames
        self.evidence = evidence
    }
}

struct InputLatency: Hashable, Sendable {
    let reportedFrames: Int64
    let measured: MeasuredLatency?

    init(reportedFrames: Int64, measured: MeasuredLatency? = nil) throws(TakeLedgerError) {
        guard reportedFrames >= 0 else { throw .negativeLatency(reportedFrames) }
        self.reportedFrames = reportedFrames
        self.measured = measured
    }

    /// Nil unless a measurement exists; never falls back to `reportedFrames`.
    var measuredFrames: Int64? { measured?.frames }
}
