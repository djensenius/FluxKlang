//
//  PathDelayCompensation.swift
//  FluxKlang
//
//  Pure, integer-frame alignment of homogeneous parallel latency paths.
//

enum LatencyPathTag: ContractIDTag {}
typealias LatencyPathID = ContractID<LatencyPathTag>

/// A path has either a fresh calibration record or no usable latency evidence.
enum PathLatency: Hashable, Sendable {
    case unknown
    case recorded(CalibrationRecord)
}

/// Current configuration and latency evidence for one uniquely identified path.
struct CompensationPath: Hashable, Sendable {
    let id: LatencyPathID
    let current: CalibrationConfiguration
    let latency: PathLatency
}

/// Delay to add to one path; entries retain the latency kind that was measured.
struct CompensationEntry: Hashable, Sendable {
    let path: LatencyPathID
    let kind: LatencyKind
    let latencyFrames: Int64
    let uncertaintyFrames: Int64?
    let addedFrames: Int64

    fileprivate init(path: LatencyPathID, kind: LatencyKind, latencyFrames: Int64,
                     uncertaintyFrames: Int64?, addedFrames: Int64) {
        self.path = path
        self.kind = kind
        self.latencyFrames = latencyFrames
        self.uncertaintyFrames = uncertaintyFrames
        self.addedFrames = addedFrames
    }
}

/// A bounded pairwise error, or unstated when no measured uncertainty exists.
enum MisalignmentBound: Hashable, Sendable {
    case withinFrames(Int64)
    case unstated
}

/// An aligned immutable plan with deterministic path ordering.
struct CompensationPlan: Hashable, Sendable {
    let sampleRateHz: Int
    let targetFrames: Int64
    let entries: [CompensationEntry]
    let slowestPaths: [LatencyPathID]
    let misalignment: MisalignmentBound

    fileprivate init(sampleRateHz: Int, targetFrames: Int64, entries: [CompensationEntry],
                     slowestPaths: [LatencyPathID], misalignment: MisalignmentBound) {
        self.sampleRateHz = sampleRateHz
        self.targetFrames = targetFrames
        self.entries = entries
        self.slowestPaths = slowestPaths
        self.misalignment = misalignment
    }
}

/// A stale record and its complete ordered list of changed configuration dimensions.
struct StalePath: Hashable, Sendable {
    let path: LatencyPathID
    let reasons: [CalibrationStaleReason]
}

/// The first reason parallel paths cannot be compensated.
enum UnalignableReason: Hashable, Sendable {
    case noPaths
    case tooManyPaths(count: Int)
    case duplicatePath(LatencyPathID)
    case unknownLatency([LatencyPathID])
    case staleCalibration([StalePath])
    case sampleRateMismatch([Int])
    case mixedKinds([LatencyKind])
    case misalignmentBoundOverflow
}

/// A complete alignment plan or a typed refusal; neither outcome changes any input.
enum CompensationOutcome: Hashable, Sendable {
    case aligned(CompensationPlan)
    case unalignable(UnalignableReason)
}

/// Computes whole-frame compensation to the slowest fresh path.
enum PathDelayCompensation {
    static let maximumPaths = 64

    /// Validates in the documented precedence order, then aligns only homogeneous latency kinds.
    static func align(_ paths: [CompensationPath]) -> CompensationOutcome {
        guard !paths.isEmpty else { return .unalignable(.noPaths) }
        guard paths.count <= maximumPaths else { return .unalignable(.tooManyPaths(count: paths.count)) }

        let ordered = paths.sorted { $0.id < $1.id }
        if let refusal = structuralEvidenceRefusal(in: ordered) { return .unalignable(refusal) }

        let rates = Array(Set(ordered.map { $0.current.stream.sampleRateHz })).sorted()
        guard rates.count == 1, let sampleRate = rates.first else {
            return .unalignable(.sampleRateMismatch(rates))
        }

        let records = ordered.compactMap { path -> (CompensationPath, CalibrationRecord)? in
            guard case .recorded(let record) = path.latency else { return nil }
            return (path, record)
        }
        let kinds = Array(Set(records.map { $0.1.measurement.kind })).sorted { $0.rawValue < $1.rawValue }
        guard kinds.count == 1, let kind = kinds.first else { return .unalignable(.mixedKinds(kinds)) }
        guard let misalignment = misalignmentBound(kind: kind, records: records) else {
            return .unalignable(.misalignmentBoundOverflow)
        }

        let target = records.map { $0.1.measurement.frames }.max() ?? 0
        let entries = records.map { path, record in
            let measurement = record.measurement
            return CompensationEntry(path: path.id, kind: measurement.kind, latencyFrames: measurement.frames,
                                     uncertaintyFrames: measurement.uncertaintyFrames,
                                     addedFrames: target - measurement.frames)
        }
        let slowest = entries.filter { $0.addedFrames == 0 }.map(\.path)
        return .aligned(CompensationPlan(sampleRateHz: sampleRate, targetFrames: target, entries: entries,
                                         slowestPaths: slowest, misalignment: misalignment))
    }

    private static func structuralEvidenceRefusal(in ordered: [CompensationPath]) -> UnalignableReason? {
        var seen = Set<LatencyPathID>()
        let duplicates = ordered.compactMap { seen.insert($0.id).inserted ? nil : $0.id }
        if let duplicate = duplicates.first { return .duplicatePath(duplicate) }

        let unknown = ordered.compactMap { path -> LatencyPathID? in
            if case .unknown = path.latency { path.id } else { nil }
        }
        if !unknown.isEmpty { return .unknownLatency(unknown) }

        let stale = ordered.compactMap { path -> StalePath? in
            guard case .recorded(let record) = path.latency else { return nil }
            let reasons = record.staleReasons(against: path.current)
            return reasons.isEmpty ? nil : StalePath(path: path.id, reasons: reasons)
        }
        if !stale.isEmpty { return .staleCalibration(stale) }
        return nil
    }

    private static func misalignmentBound(
        kind: LatencyKind,
        records: [(CompensationPath, CalibrationRecord)]
    ) -> MisalignmentBound? {
        guard kind.isMeasured else { return .unstated }
        guard records.count > 1 else { return .withinFrames(0) }
        let uncertainties = records.compactMap { $0.1.measurement.uncertaintyFrames }.sorted(by: >)
        let largest = uncertainties.first ?? 0
        let secondLargest = uncertainties.dropFirst().first ?? 0
        let (sum, overflow) = largest.addingReportingOverflow(secondLargest)
        guard !overflow else { return nil }
        return .withinFrames(sum)
    }
}
