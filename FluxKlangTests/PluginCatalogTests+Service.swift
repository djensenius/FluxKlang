import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginCatalogTests {
    struct Service {
        @Test func instantiatingProbesAreRefusedDuringPerformanceBeforeScanning() async throws {
            let verb = try PluginCatalogTests.identity("Verb")
            let scanner = ScriptedScanner(.success(PluginScanReport(entries: [
                PluginScanEntry(identity: verb, outcome: .probeCrashed)
            ])))
            let service = PluginCatalogService(scanner: scanner)
            await service.setActivity(.performing)
            await #expect(throws: PluginCatalogServiceError.probeRefusedDuringPerformance) {
                try await service.scan(depth: .instantiatingProbe)
            }
            #expect(await scanner.recorder.requests.isEmpty)
            #expect(await service.catalog == PluginCatalog())

            await service.setActivity(.idle)
            _ = try await service.scan(depth: .instantiatingProbe)
            #expect(await service.catalog.quarantined == [verb.id])
            await #expect(throws: PluginCatalogServiceError.rejected(.probedQuarantinedPlugin(verb.id))) {
                try await service.scan(depth: .instantiatingProbe)
            }
            #expect(await scanner.recorder.requests.map(\.quarantined) == [[], [verb.id]])
        }

        @Test func metadataScansContinueWhenPerformanceStartsMidScan() async throws {
            let verb = try PluginCatalogTests.identity("Verb")
            let gate = ScanGate()
            let report = try PluginScanReport(entries: [PluginCatalogTests.described(verb)])
            let service = PluginCatalogService(scanner: GatedScanner(gate: gate, report: report))
            let scan = Task { try await service.scan(depth: .metadataOnly) }
            await gate.waitUntilEntered()
            await service.setActivity(.performing)
            await gate.open()
            #expect(try await scan.value.changed == [verb.id])
            #expect(await gate.observedCancellation == false)
        }

        @Test func performanceStartingMidProbeCancelsItAndKeepsOnlyQuarantine() async throws {
            let (verb, echo) = try (PluginCatalogTests.identity("Verb"), PluginCatalogTests.identity("Echo"))
            let gate = ScanGate()
            let report = try PluginScanReport(entries: [
                PluginCatalogTests.described(echo), PluginScanEntry(identity: verb, outcome: .probeCrashed)
            ])
            let service = PluginCatalogService(scanner: GatedScanner(gate: gate, report: report))
            let scan = Task { try await service.scan(depth: .instantiatingProbe) }
            await gate.waitUntilEntered()
            await service.setActivity(.performing)
            await gate.open()
            await #expect(throws: PluginCatalogServiceError.probeInterruptedByPerformance) { try await scan.value }

            #expect(await gate.observedCancellation == true)
            let catalog = await service.catalog
            #expect(Set(catalog.entries.keys) == [verb.id] && catalog.quarantined == [verb.id])
            #expect(catalog.scanState == .notScanned && catalog.generation.value == 2)
        }

        @Test func performanceThatEndsBeforeTheProbeReturnsStillDiscardsItsMetadata() async throws {
            let (verb, echo) = try (PluginCatalogTests.identity("Verb"), PluginCatalogTests.identity("Echo"))
            let gate = ScanGate()
            let report = try PluginScanReport(entries: [
                PluginCatalogTests.described(echo), PluginScanEntry(identity: verb, outcome: .probeCrashed)
            ])
            let service = PluginCatalogService(scanner: GatedScanner(gate: gate, report: report))
            let scan = Task { try await service.scan(depth: .instantiatingProbe) }
            await gate.waitUntilEntered()
            await service.setActivity(.performing)
            await service.setActivity(.idle)
            await gate.open()
            await #expect(throws: PluginCatalogServiceError.probeInterruptedByPerformance) { try await scan.value }

            let catalog = await service.catalog
            let expected = try PluginCatalog().generation.next()
            #expect(Set(catalog.entries.keys) == [verb.id] && catalog.quarantined == [verb.id])
            #expect(catalog.scanState == .notScanned && catalog.generation == expected)
        }

        @Test func rejectedReportsStillCommitTheirQuarantineEvidence() async throws {
            let (verb, echo) = try (PluginCatalogTests.identity("Verb"), PluginCatalogTests.identity("Echo"))
            let report = try PluginScanReport(entries: [
                PluginScanEntry(identity: verb, outcome: .probeCrashed),
                PluginCatalogTests.described(echo), PluginCatalogTests.described(echo)
            ])
            let service = PluginCatalogService(scanner: ScriptedScanner(.success(report)))
            await #expect(throws: PluginCatalogServiceError.rejected(.duplicateIdentity(echo.id))) {
                try await service.scan(depth: .instantiatingProbe)
            }
            let catalog = await service.catalog
            #expect(catalog.quarantined == [verb.id] && catalog.entries[echo.id] == nil)
            #expect(await service.probeBlocked == false)
        }

        @Test func rejectedBatchesWithProbeEvidenceBlockProbesUntilCleared() async throws {
            let (verb, echo, gone) = try (PluginCatalogTests.identity("Verb"), PluginCatalogTests.identity("Echo"),
                                          PluginCatalogTests.identity("Gone"))
            var start = PluginCatalog()
            _ = try start.apply(PluginScanReport(entries: [PluginCatalogTests.described(gone)]),
                                for: start.request(depth: .metadataOnly))
            _ = try start.apply(PluginScanReport(entries: []), for: start.request(depth: .metadataOnly))
            _ = try start.recordQuarantine([PluginQuarantineEvidence(identity: verb, reason: .probeCrashed)])
            let mixed = PluginScanReport(entries: [
                PluginScanEntry(identity: echo, outcome: .probeCrashed),
                PluginScanEntry(identity: verb, outcome: .probeTimedOut)
            ])
            let scanner = ScriptedScanner(.success(mixed))
            let service = PluginCatalogService(scanner: scanner, catalog: start)
            await #expect(throws: PluginCatalogServiceError.rejected(.probedQuarantinedPlugin(verb.id))) {
                try await service.scan(depth: .instantiatingProbe)
            }
            #expect(await service.catalog == start)
            #expect(await service.probeBlock == .evidenceRejected)
            await #expect(throws: PluginCatalogServiceError.probeBlockedEvidenceUnrecorded) {
                try await service.scan(depth: .instantiatingProbe)
            }
            #expect(await scanner.recorder.requests.count == 1)

            _ = try await service.forget(gone.id)
            #expect(await service.probeBlock == .evidenceRejected)
            await service.clearProbeBlock()
            #expect(await service.probeBlocked == false)
        }

        @Test(arguments: [false, true])
        func evidenceRefusedForOtherThanRoomStaysBlockedAfterForget(_ overflow: Bool) async throws {
            let (verb, gone) = try (PluginCatalogTests.identity("Verb"), PluginCatalogTests.identity("Gone"))
            let initial = try overflow ? Generation(Generation.maximumValue - 2) : .initial
            var start = PluginCatalog(generation: initial)
            _ = try start.apply(PluginScanReport(entries: [PluginCatalogTests.described(gone)]),
                                for: start.request(depth: .metadataOnly))
            _ = try start.apply(PluginScanReport(entries: []), for: start.request(depth: .metadataOnly))
            let crash = PluginQuarantineEvidence(identity: verb, reason: .probeCrashed)
            let evidence = overflow ? [crash] : [crash, crash]
            let scanner = ScriptedScanner(.failure(.cancelled(quarantine: evidence)))
            let service = PluginCatalogService(scanner: scanner, catalog: start)
            let refusal: PluginCatalogError = overflow ? .generationOverflow : .duplicateIdentity(verb.id)
            await #expect(throws: PluginCatalogServiceError.evidenceNotRecorded(refusal, original: .cancelled)) {
                try await service.scan(depth: .instantiatingProbe)
            }
            #expect(await service.catalog == start)
            #expect(await service.probeBlock == .evidenceRejected)

            _ = try? await service.forget(gone.id)
            #expect(await service.catalog.entries[gone.id] == (overflow ? start.entries[gone.id] : nil))
            #expect(await service.probeBlock == .evidenceRejected)
            await #expect(throws: PluginCatalogServiceError.probeBlockedEvidenceUnrecorded) {
                try await service.scan(depth: .instantiatingProbe)
            }
            #expect(await scanner.recorder.requests.count == 1)
        }

        @Test func oversizedEvidenceBatchesStayBlockedAfterForget() async throws {
            let gone = try PluginCatalogTests.identity("Gone")
            var start = PluginCatalog()
            _ = try start.apply(PluginScanReport(entries: [PluginCatalogTests.described(gone)]),
                                for: start.request(depth: .metadataOnly))
            _ = try start.apply(PluginScanReport(entries: []), for: start.request(depth: .metadataOnly))
            let evidence = try PluginCatalogTests.evidence(count: PluginCatalogLimits.entries + 1)
            let scanner = ScriptedScanner(.failure(.cancelled(quarantine: evidence)))
            let service = PluginCatalogService(scanner: scanner, catalog: start)
            await #expect(throws: PluginCatalogServiceError.evidenceNotRecorded(
                .evidenceBatchTooLarge(maximum: PluginCatalogLimits.entries), original: .cancelled
            )) {
                try await service.scan(depth: .instantiatingProbe)
            }
            #expect(await service.probeBlock == .evidenceRejected)
            _ = try await service.forget(gone.id)
            #expect(await service.probeBlock == .evidenceRejected)
            await #expect(throws: PluginCatalogServiceError.probeBlockedEvidenceUnrecorded) {
                try await service.scan(depth: .instantiatingProbe)
            }
        }

        @Test func exhaustedHeadroomKeepsTheScannerErrorAlongsideTheRefusal() async throws {
            var full = try PluginCatalogTests.fullCatalog()
            _ = try full.recordQuarantine(PluginCatalogTests.evidence(count: PluginCatalogLimits.quarantineHeadroom))
            let verb = try PluginCatalogTests.identity("Verb")
            let failure = PluginScannerError.cancelled(quarantine: [.init(identity: verb, reason: .probeTimedOut)])
            let service = PluginCatalogService(scanner: ScriptedScanner(.failure(failure)), catalog: full)
            let maximum = PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom
            await #expect(throws: PluginCatalogServiceError.evidenceNotRecorded(
                .quarantineHeadroomExhausted(maximum: maximum), original: .cancelled
            )) {
                try await service.scan(depth: .instantiatingProbe)
            }
            #expect(await service.catalog == full)
        }

        @Test(arguments: [true, false])
        func unrecordedEvidenceBlocksProbesUntilRoomOrConfirmation(_ viaForget: Bool) async throws {
            var full = try PluginCatalogTests.fullCatalog()
            _ = try full.apply(PluginScanReport(entries: []), for: full.request(depth: .metadataOnly))
            _ = try full.recordQuarantine(PluginCatalogTests.evidence(count: PluginCatalogLimits.quarantineHeadroom))
            let verb = try PluginCatalogTests.identity("Verb")
            let lost = PluginScannerError.cancelled(quarantine: [.init(identity: verb, reason: .probeCrashed)])
            let scanner = ScriptedScanner(.failure(lost), .success(PluginScanReport(entries: [])))
            let service = PluginCatalogService(scanner: scanner, catalog: full)
            let maximum = PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom
            await #expect(throws: PluginCatalogServiceError.evidenceNotRecorded(
                .quarantineHeadroomExhausted(maximum: maximum), original: .cancelled
            )) {
                try await service.scan(depth: .instantiatingProbe)
            }
            #expect(await service.probeBlocked)

            await #expect(throws: PluginCatalogServiceError.probeBlockedEvidenceUnrecorded) {
                try await service.scan(depth: .instantiatingProbe)
            }
            #expect(await scanner.recorder.requests.count == 1)
            _ = try await service.scan(depth: .metadataOnly)
            #expect(await service.probeBlocked)
            #expect(await scanner.recorder.requests.count == 2)

            let bare = await service.catalog.quarantined.sorted()[0]
            let capped = PluginCatalogError.tooManyEntries(maximum: PluginCatalogLimits.entries)
            await #expect(throws: PluginCatalogServiceError.rejected(capped)) {
                try await service.releaseQuarantine(bare)
            }
            #expect(await service.probeBlocked)
            if viaForget {
                let missing = try PluginCatalogTests.report(count: 1).entries[0].identity.id
                _ = try await service.forget(missing)
            } else {
                await service.clearProbeBlock()
            }
            #expect(await service.probeBlocked == false)
            _ = try await service.scan(depth: .instantiatingProbe)
            #expect(await scanner.recorder.requests.count == 3)
        }

        @Test(arguments: [PluginScannerError.cancelled(quarantine: []), .unavailable(quarantine: [])])
        func scannerFailuresWithoutEvidenceLeaveTheCatalogUnchanged(_ failure: PluginScannerError) async throws {
            let service = PluginCatalogService(scanner: ScriptedScanner(.failure(failure)))
            let expected: PluginCatalogServiceError = failure == .unavailable(quarantine: [])
                ? .scannerUnavailable : .cancelled
            await #expect(throws: expected) { try await service.scan(depth: .metadataOnly) }
            #expect(await service.catalog == PluginCatalog())
        }

        @Test(arguments: [true, false])
        func scannerFailuresKeepProbeQuarantineEvidence(_ cancelled: Bool) async throws {
            let verb = try PluginCatalogTests.identity("Verb")
            let evidence = [PluginQuarantineEvidence(identity: verb, reason: .probeTimedOut)]
            let failure: PluginScannerError = cancelled
                ? .cancelled(quarantine: evidence) : .unavailable(quarantine: evidence)
            let service = PluginCatalogService(scanner: ScriptedScanner(.failure(failure)))
            let expected: PluginCatalogServiceError = cancelled ? .cancelled : .scannerUnavailable
            await #expect(throws: expected) { try await service.scan(depth: .instantiatingProbe) }
            let catalog = await service.catalog
            #expect(catalog.entries[verb.id]?.quarantine == .probeTimedOut && catalog.scanState == .notScanned)
        }

        @Test func probeEvidenceFromAMetadataScanIsRejected() async throws {
            let verb = try PluginCatalogTests.identity("Verb")
            let evidence = [PluginQuarantineEvidence(identity: verb, reason: .probeCrashed)]
            let service = PluginCatalogService(scanner: ScriptedScanner(.failure(.cancelled(quarantine: evidence))))
            await #expect(throws: PluginCatalogServiceError.rejected(.probeOutcomeFromMetadataScan(verb.id))) {
                try await service.scan(depth: .metadataOnly)
            }
            #expect(await service.catalog == PluginCatalog())
        }

        @Test func cancellingAnInFlightProbeDiscardsMetadataButKeepsQuarantine() async throws {
            let (verb, echo) = try (PluginCatalogTests.identity("Verb"), PluginCatalogTests.identity("Echo"))
            let gate = ScanGate()
            let report = try PluginScanReport(entries: [
                PluginCatalogTests.described(echo), PluginScanEntry(identity: verb, outcome: .probeCrashed)
            ])
            let service = PluginCatalogService(scanner: GatedScanner(gate: gate, report: report))
            let scan = Task { try await service.scan(depth: .instantiatingProbe) }
            await gate.waitUntilEntered()

            await #expect(throws: PluginCatalogServiceError.scanInProgress) {
                try await service.scan(depth: .metadataOnly)
            }
            await #expect(throws: PluginCatalogServiceError.scanInProgress) {
                try await service.releaseQuarantine(verb.id)
            }
            await #expect(throws: PluginCatalogServiceError.scanInProgress) { try await service.forget(echo.id) }
            scan.cancel()
            await gate.open()
            await #expect(throws: PluginCatalogServiceError.cancelled) { try await scan.value }
            #expect(await gate.observedCancellation == true)
            #expect(await Set(service.catalog.entries.keys) == [verb.id])
            #expect(await service.catalog.quarantined == [verb.id])

            await #expect(throws: PluginCatalogServiceError.rejected(.cannotForget(echo.id, .unknown))) {
                try await service.forget(echo.id)
            }
        }

        @Test func alreadyCancelledCallersNeverReachTheScanner() async throws {
            let scanner = ScriptedScanner(.success(PluginScanReport(entries: [])))
            let service = PluginCatalogService(scanner: scanner)
            let scan = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await service.scan(depth: .metadataOnly)
            }
            await #expect(throws: PluginCatalogServiceError.cancelled) { try await scan.value }
            #expect(await scanner.recorder.requests.isEmpty)
        }
    }
}

extension PluginCatalogTests {
    actor ScanRecorder {
        private(set) var requests: [PluginScanRequest] = []

        func record(_ request: PluginScanRequest) -> Int {
            requests.append(request)
            return requests.count - 1
        }
    }

    /// Answers each pass with the next scripted result, repeating the last one.
    struct ScriptedScanner: PluginComponentScanner {
        let results: [Result<PluginScanReport, PluginScannerError>]
        let recorder = ScanRecorder()

        init(_ results: Result<PluginScanReport, PluginScannerError>...) {
            self.results = results
        }

        func scan(_ request: PluginScanRequest) async throws(PluginScannerError) -> PluginScanReport {
            let index = await recorder.record(request)
            return try results[min(index, results.count - 1)].get()
        }
    }

    /// Holds a scan open until the test opens the gate. It ignores cancellation,
    /// like a scanner that finishes its pass after the caller stopped waiting,
    /// but records whether cancellation reached it.
    actor ScanGate {
        private var entered = false
        private var isOpen = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?
        private(set) var observedCancellation: Bool?

        func enter() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            guard !isOpen else { return }
            await withCheckedContinuation { release = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func open() {
            isOpen = true
            release?.resume()
            release = nil
        }

        func noteCancellation(_ cancelled: Bool) {
            observedCancellation = cancelled
        }
    }

    struct GatedScanner: PluginComponentScanner {
        let gate: ScanGate
        let report: PluginScanReport

        func scan(_ request: PluginScanRequest) async throws(PluginScannerError) -> PluginScanReport {
            await gate.enter()
            await gate.noteCancellation(Task.isCancelled)
            return report
        }
    }
}
