//
//  PluginCatalogService.swift
//  FluxKlang
//
//  Runs one scan at a time through an injected scanner and commits its report
//  to the catalog all or nothing. Host activity is actor state: instantiating
//  probes are refused while performing, an in-flight probe is cancelled when a
//  performance starts, and its metadata is discarded if performing began while
//  it ran, even if performing has ended again by the time the probe returns.
//  Probe crashes and hangs are still recorded from a discarded, cancelled,
//  rejected or failed pass, so crash isolation never depends on completion.
//  If credible evidence cannot be committed (catalog full), further probes are
//  blocked until forget/release leaves room or the user clears the block;
//  metadata-only scans stay allowed.
//  Scans run on this actor, never on a render callback. Qualified probe
//  containment (#71/#72, evidence in #78) is a non-goal here.
//

import Foundation

enum PluginCatalogServiceError: Error, Equatable, Sendable {
    case probeRefusedDuringPerformance
    /// Earlier probe evidence could not be recorded; forget missing entries or clear the block.
    case probeBlockedEvidenceUnrecorded
    /// Performing started while a probe ran; only its quarantine evidence was kept.
    case probeInterruptedByPerformance
    case scanInProgress
    case cancelled
    case scannerUnavailable
    case rejected(PluginCatalogError)
    /// Quarantine evidence could not be committed (for example, the quarantine
    /// headroom is exhausted) while the scan was already failing as `original`.
    indirect case evidenceNotRecorded(PluginCatalogError, original: PluginCatalogServiceError)
}

actor PluginCatalogService {
    private typealias ScanTask = Task<Result<PluginScanReport, PluginScannerError>, Never>

    private let scanner: any PluginComponentScanner
    private(set) var catalog: PluginCatalog
    private(set) var activity: PluginHostActivity
    private var inFlight: InFlight?
    /// Latched when credible quarantine evidence was lost, so no further probe
    /// can crash a component the catalog cannot remember.
    private(set) var probeBlocked = false

    private struct InFlight {
        let depth: PluginScanDepth
        let task: ScanTask
        /// Set once performing starts during an instantiating probe; never cleared.
        var interrupted = false
    }

    init(
        scanner: any PluginComponentScanner, catalog: PluginCatalog = PluginCatalog(),
        activity: PluginHostActivity = .idle
    ) {
        self.scanner = scanner
        self.catalog = catalog
        self.activity = activity
    }

    func setActivity(_ activity: PluginHostActivity) {
        self.activity = activity
        if activity == .performing, inFlight?.depth == .instantiatingProbe {
            inFlight?.interrupted = true
            inFlight?.task.cancel()
        }
    }

    func scan(depth: PluginScanDepth) async throws(PluginCatalogServiceError) -> PluginCatalogChange {
        guard depth == .metadataOnly || activity == .idle else { throw .probeRefusedDuringPerformance }
        guard depth == .metadataOnly || !probeBlocked else { throw .probeBlockedEvidenceUnrecorded }
        guard inFlight == nil else { throw .scanInProgress }
        guard !Task.isCancelled else { throw .cancelled }
        let request = catalog.request(depth: depth)
        let scanner = scanner
        let task = ScanTask {
            do throws(PluginScannerError) {
                return .success(try await scanner.scan(request))
            } catch {
                return .failure(error)
            }
        }
        inFlight = InFlight(depth: depth, task: task)
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        let interrupted = inFlight?.interrupted ?? false
        inFlight = nil
        return try settle(result, for: request, interrupted: interrupted)
    }

    func releaseQuarantine(_ id: PluginID) throws(PluginCatalogServiceError) -> PluginCatalogChange {
        guard inFlight == nil else { throw .scanInProgress }
        let change = try mutate { (catalog: inout PluginCatalog) throws(PluginCatalogError) in
            try catalog.releaseQuarantine(id)
        }
        unblockProbesIfRoom()
        return change
    }

    func forget(_ id: PluginID) throws(PluginCatalogServiceError) -> PluginCatalogChange {
        guard inFlight == nil else { throw .scanInProgress }
        let change = try mutate { (catalog: inout PluginCatalog) throws(PluginCatalogError) in
            try catalog.forget(id)
        }
        unblockProbesIfRoom()
        return change
    }

    /// The user's explicit confirmation that probing may resume without room
    /// for new quarantine evidence.
    func clearProbeBlock() {
        probeBlocked = false
    }

    func resolve(_ reference: PluginReference) -> PluginResolution {
        catalog.resolve(reference)
    }

    private func settle(
        _ result: Result<PluginScanReport, PluginScannerError>, for request: PluginScanRequest, interrupted: Bool
    ) throws(PluginCatalogServiceError) -> PluginCatalogChange {
        switch result {
        case .failure(let error):
            let original: PluginCatalogServiceError = switch error {
            case _ where interrupted: .probeInterruptedByPerformance
            case .cancelled: .cancelled
            case .unavailable: .scannerUnavailable
            }
            try record(error.quarantine, for: request, original: original)
            throw original
        case .success(let report):
            guard !interrupted, !Task.isCancelled else {
                let original: PluginCatalogServiceError = interrupted ? .probeInterruptedByPerformance : .cancelled
                try record(report.quarantineEvidence, for: request, original: original)
                throw original
            }
            do throws(PluginCatalogError) {
                return try catalog.apply(report, for: request)
            } catch {
                try record(report.quarantineEvidence, for: request, original: .rejected(error))
                throw .rejected(error)
            }
        }
    }

    /// Commits the evidence of a pass that is failing as `original`. Evidence
    /// that is not credible is a rejection of the scanner; a credible commit
    /// that cannot be made keeps `original` alongside the reason.
    private func record(
        _ evidence: [PluginQuarantineEvidence], for request: PluginScanRequest,
        original: PluginCatalogServiceError
    ) throws(PluginCatalogServiceError) {
        guard !evidence.isEmpty else { return }
        do throws(PluginCatalogError) {
            try PluginCatalog.check(evidence, for: request)
        } catch {
            throw original == .rejected(error) ? original : .rejected(error)
        }
        do throws(PluginCatalogError) {
            _ = try catalog.recordQuarantine(evidence)
        } catch {
            probeBlocked = true
            throw original == .rejected(error) ? original : .evidenceNotRecorded(error, original: original)
        }
    }

    private func unblockProbesIfRoom() {
        if catalog.hasQuarantineRoom { probeBlocked = false }
    }

    private func mutate(
        _ body: (inout PluginCatalog) throws(PluginCatalogError) -> PluginCatalogChange
    ) throws(PluginCatalogServiceError) -> PluginCatalogChange {
        do throws(PluginCatalogError) {
            return try body(&catalog)
        } catch {
            throw .rejected(error)
        }
    }
}
