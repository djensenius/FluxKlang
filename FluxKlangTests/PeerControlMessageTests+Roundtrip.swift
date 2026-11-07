import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerControlMessageTests {
    /// Encodes `message`, expects bytes, and decodes them back to an equal message.
    func expectRoundTrip(_ message: PeerControlMessage, _ note: String = "", session: PeerSyncSession = F.session()) {
        let bytes = F.bytes(message)
        #expect(!bytes.isEmpty, "encodes \(note)")
        #expect(F.decode(bytes, session: session) == .success(message), "round trip \(note)")
        #expect(F.encode(message) == .success(bytes), "stable \(note)")
    }

    @Test func everyOperationRoundTripsIncludingTheBoundaryNumbers() {
        let parameter = F.pid("p")
        let operations: [CommandOperation] = [
            .set(parameter, F.value(-0.0, .decibels)), .ramp(parameter, F.value(1, .percent), milliseconds: 0),
            .ramp(parameter, F.value(1, .pan), milliseconds: 60_000), .bind(F.ident("route.1")),
            .recall(F.ident("patch.1")), .trigger(F.ident("action.1")), .start, .stop,
            .locate(ticks: 0), .locate(ticks: Int64.max), .panic, .safeMute,
            .propose(F.ident("draft.1")), .editDraft(F.ident("draft.2"))
        ]
        for operation in operations {
            expectRoundTrip(F.command(F.intent(operation: operation)), "\(operation)")
            expectRoundTrip(F.command(F.intent(operation: operation, connection: false)), "\(operation) no connection")
        }
    }

    @Test func everyClassOriginAndUnitRoundTrips() {
        for commandClass in ControlClass.allCases {
            for origin in [CommandOrigin.human, .controller, .assistant] {
                expectRoundTrip(F.command(F.intent(commandClass: commandClass, origin: origin)))
            }
        }
        for unit in [ParameterUnit.decibels, .normalized, .percent, .pan, .index, .boolean] {
            expectRoundTrip(F.snapshot([F.pid("a"): F.value(0.5, unit)]), "\(unit)")
        }
    }

    @Test func everyRejectionAndValueErrorRoundTrips() {
        let rejections: [CommandRejection] = [
            .permissionDenied, .permissionChanged, .staleRevision(expected: F.rev(0), found: F.rev(1 << 53 - 1)),
            .unknownParameter(F.pid("p")), .missingValue, .scopeDenied, .classMismatch, .unsupportedOperation,
            .revisionChanged, .invalidValue(.nonFinite), .invalidValue(.invalidDescriptor),
            .invalidValue(.invalidRamp), .invalidValue(.unitMismatch(expected: .pan, found: .index)),
            .invalidValue(.notIntegral(2.5)), .invalidValue(.outOfRange(-1.5, lower: 0, upper: 1)),
            .invalidValue(.aboveCeiling(9, ceiling: 6))
        ]
        for rejection in rejections {
            expectRoundTrip(F.result(.refused(.command(.rejected(rejection)))), "\(rejection)")
            expectRoundTrip(F.result(.replayed(.refused(.rejected(rejection)))), "replayed \(rejection)")
        }
    }

    @Test func everyOutcomeCompletionRefusalAndStaleKindRoundTrips() {
        var outcomes: [PeerCommandOutcome] = [
            .admitted, .inFlight, .replayed(.applied(revisions: F.revisions)), .replayed(.refused(.applied)),
            .replayed(.refused(.stale(.connectionEpoch))), .replayed(.refused(.stale(.hostEpoch))),
            .refused(.command(.applied)), .refused(.sessionRetired(.hostEpoch)),
            .refused(.sessionRetired(.connectionEpoch)),
            .refused(.sessionRetired(.generation(F.generationKey(.transport, "mus.main")))),
            .refused(.outOfSequence(expected: F.seq(0), found: F.seq(1 << 53 - 1))),
            .refused(.sessionFailed), .refused(.conflictingReuse)
        ]
        for kind in GenerationKind.allCases {
            outcomes.append(.refused(.command(.stale(.generation(F.generationKey(kind, "g.\(kind.rawValue)"))))))
        }
        for outcome in outcomes { expectRoundTrip(F.result(outcome), "\(outcome)") }
    }

    @Test func ledgerCapacityRoundTripsAtZeroAndUInt32MaxAndRefusesOutsideThatRange() {
        for capacity in [0, 1, Int(UInt32.max)] {
            expectRoundTrip(F.result(.refused(.ledgerFull(capacity: capacity))), "\(capacity)")
        }
        let tooBig = F.result(.refused(.ledgerFull(capacity: Int(UInt32.max) + 1)))
        #expect(F.encode(tooBig) == .failure(.unencodable(.integerOutOfRange(Int(UInt32.max) + 1))))
        let negative = F.result(.refused(.ledgerFull(capacity: -1)))
        #expect(F.encode(negative) == .failure(.unencodable(.integerOutOfRange(-1))))
    }

    @Test func rampDurationAndLocateTicksAcceptTheirBoundsAndTheFactoryRefusesBeyond() {
        let parameter = F.pid("p")
        func intent(_ operation: CommandOperation) -> CommandIntentFields {
            CommandIntentFields(id: F.cid("c"), commandClass: .live, origin: .human,
                                hostEpoch: HostEpoch(host: F.host, generation: F.gen(1)),
                                connectionEpoch: nil, revisions: F.revisions, operation: operation,
                                permission: PermissionFingerprint(rawValue: "x"))
        }
        #expect((try? CommandIntent(intent(.ramp(parameter, F.value(1), milliseconds: 60_000)))) != nil)
        #expect((try? CommandIntent(intent(.ramp(parameter, F.value(1), milliseconds: 60_001)))) == nil)
        #expect((try? CommandIntent(intent(.locate(ticks: -1)))) == nil)
    }

    @Test func negativeZeroSubnormalsAndExtremesKeepTheirBitPattern() throws {
        let numbers: [Double] = [-0.0, 0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
                                 .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNormalMagnitude]
        for number in numbers {
            let bytes = F.bytes(F.snapshot([F.pid("a"): F.value(number)]))
            #expect(bytes.suffix(9).prefix(8) == F.u64(number.bitPattern)[...])
            guard case .snapshot(let decoded)? = try? F.decode(bytes).get() else {
                Issue.record("snapshot did not decode for \(number)")
                continue
            }
            let value = try #require(decoded.values[F.pid("a")])
            #expect(value.value.bitPattern == number.bitPattern)
        }
    }

    @Test func nonFiniteValuesAreUnencodableOrFactoryRefusedEverywhere() {
        for number in [Double.nan, .infinity, -.infinity] {
            #expect(F.encode(F.snapshot([F.pid("a"): F.value(number)])) == .failure(.nonFiniteValue))
            #expect(F.encode(F.delta(updates: [F.pid("a"): F.value(number)])) == .failure(.nonFiniteValue))
            let outOfRange = F.result(.refused(.command(.rejected(.invalidValue(.notIntegral(number))))))
            #expect(F.encode(outOfRange) == .failure(.nonFiniteValue))
            let ranged = F.result(.refused(.command(.rejected(.invalidValue(.outOfRange(1, lower: number, upper: 1))))))
            #expect(F.encode(ranged) == .failure(.nonFiniteValue))
            let ceiling = F.result(.refused(.command(.rejected(.invalidValue(.aboveCeiling(1, ceiling: number))))))
            #expect(F.encode(ceiling) == .failure(.nonFiniteValue))
        }
    }

    @Test func sequencesAndRevisionsRoundTripAtZeroAndTheTop() {
        let top = (1 << 53) - 1
        let revisions = CommandRevisions(patch: F.rev(0), capability: F.rev(top), permission: F.rev(0),
                                         parameter: F.rev(top), graph: F.rev(1))
        for sequence in [0, 1, top] {
            let snapshot = PeerSyncSnapshot(session: F.session(), sequence: F.seq(sequence),
                                            revisions: revisions, values: [:])
            expectRoundTrip(.snapshot(snapshot), "sequence \(sequence)")
            expectRoundTrip(F.resync(.repeated(F.seq(sequence)), lastApplied: sequence))
        }
        let generations = F.session(host: top, connection: 1)
        expectRoundTrip(F.snapshot([:], session: generations), session: generations)
    }

    @Test func emptyMessagesAndBoundaryIdsRoundTrip() {
        expectRoundTrip(F.snapshot([:]))
        expectRoundTrip(F.delta())
        let longest = String(repeating: "x", count: 128)
        expectRoundTrip(F.snapshot([F.pid("a"): F.value(1), F.pid(longest): F.value(2)]))
        expectRoundTrip(F.delta(updates: [F.pid(longest): F.value(1)], removals: [F.pid("a")]))
        let longSession = F.session(hostID: F.ident(longest), connectionID: F.ident(longest))
        expectRoundTrip(F.snapshot([:], session: longSession), session: longSession)
        expectRoundTrip(F.snapshot([:], session: longSession), session: longSession)
    }

    @Test func fingerprintsRoundTripByBytesAtTheTwoByteBoundary() {
        let two = "é"
        let longest = String(repeating: two, count: 128)
        let fingerprints = ["x", longest, longest.dropLast() + "xx", "e\u{301}", "\u{E9}",
                            String(repeating: "x", count: 256)]
        for fingerprint in fingerprints {
            let message = F.command(F.intent(permission: String(fingerprint)))
            expectRoundTrip(message, "\(fingerprint.utf8.count)")
        }
        let nfd = F.bytes(F.command(F.intent(permission: "e\u{301}")))
        let nfc = F.bytes(F.command(F.intent(permission: "\u{E9}")))
        #expect(nfd != nfc)
        guard case .command(let decoded)? = try? F.decode(nfd).get() else {
            Issue.record("nfd command did not decode")
            return
        }
        #expect(Array(decoded.intent.permission.rawValue.utf8) == Array("e\u{301}".utf8))
    }

    @Test func encodeRefusalsRunLimitsThenOverlapThenValuesAndSizeLast() {
        let nan = F.value(.nan)
        let many = Dictionary(uniqueKeysWithValues: (0...4_096).map { (F.pid("p\($0)"), $0 == 0 ? nan : F.value(0.5)) })
        #expect(F.encode(F.snapshot(many)) == .failure(.tooManyEntries(4_097)))
        var updates = Dictionary(uniqueKeysWithValues: (0..<257).map { (F.pid("u\($0)"), F.value(0.5)) })
        let overlappingMany = F.delta(updates: updates, removals: [F.pid("u0")])
        #expect(F.encode(overlappingMany) == .failure(.tooManyEntries(258)))
        updates = [F.pid("a"): nan]
        let overlapping = F.delta(updates: updates, removals: [F.pid("a")])
        #expect(F.encode(overlapping) == .failure(.unencodable(.overlappingChanges)))
        #expect(F.encode(F.delta(updates: updates)) == .failure(.nonFiniteValue))
        let manyRemovals = Set((0..<256).map { F.pid("r\($0)") })
        #expect(F.encode(F.delta(updates: [F.pid("a"): nan], removals: manyRemovals)) == .failure(.tooManyEntries(257)))
        let ids = (0..<80).map { String(format: "p.%02d", $0) }
        var values = Dictionary(uniqueKeysWithValues: ids.map { (F.pid($0), F.value(0.5)) })
        values[F.pid("p.00")] = nan
        #expect(F.encode(F.snapshot(values), frame: F.frameLimits(1_024)) == .failure(.nonFiniteValue))
    }

    @Test func everyClosedEnumerationKeepsItsFixedWireCodes() {
        let classes: [(ControlClass, UInt8)] = [(.live, 1), (.structural, 2), (.hazardous, 3), (.safety, 4),
                                                (.proposal, 5)]
        for (value, code) in classes { #expect(value.wireCode == code) }
        let origins: [(CommandOrigin, UInt8)] = [(.human, 1), (.controller, 2), (.assistant, 3)]
        for (value, code) in origins { #expect(value.wireCode == code) }
        let units: [(ParameterUnit, UInt8)] = [(.decibels, 1), (.normalized, 2), (.percent, 3), (.pan, 4),
                                              (.index, 5), (.boolean, 6)]
        for (value, code) in units { #expect(value.wireCode == code) }
        let kinds: [(GenerationKind, UInt8)] = [(.sampleClock, 1), (.transport, 2), (.musicalMap, 3), (.source, 4),
                                               (.context, 5), (.cancelScope, 6)]
        for (value, code) in kinds { #expect(value.wireCode == code) }
        #expect(PeerControlMessage.Tag.allCases.map(\.rawValue) == [1, 2, 3, 4, 5])
    }

    @Test func operationRejectionValueErrorAndStaleCodesAreFixedOnTheWire() {
        let parameter = F.pid("p")
        let operations: [(CommandOperation, UInt8)] = [
            (.set(parameter, F.value(0.5)), 1), (.ramp(parameter, F.value(0.5), milliseconds: 1), 2),
            (.bind(F.ident("r")), 3), (.recall(F.ident("r")), 4), (.trigger(F.ident("r")), 5), (.start, 6),
            (.stop, 7), (.locate(ticks: 1), 8), (.panic, 9), (.safeMute, 10), (.propose(F.ident("r")), 11),
            (.editDraft(F.ident("r")), 12)
        ]
        for (operation, code) in operations {
            #expect(F.byte(F.command(F.intent(operation: operation)), at: 76) == code, "\(operation)")
        }
        let rejections: [(CommandRejection, UInt8)] = [
            (.permissionDenied, 1), (.permissionChanged, 2), (.staleRevision(expected: F.rev(1), found: F.rev(2)), 3),
            (.unknownParameter(parameter), 4), (.missingValue, 5), (.invalidValue(.nonFinite), 6), (.scopeDenied, 7),
            (.classMismatch, 8), (.unsupportedOperation, 9), (.revisionChanged, 10)
        ]
        for (rejection, code) in rejections {
            #expect(F.byte(F.result(.refused(.command(.rejected(rejection)))), at: 16) == code, "\(rejection)")
        }
        let valueErrors: [(ParameterValueError, UInt8)] = [
            (.nonFinite, 1), (.invalidDescriptor, 2), (.invalidRamp, 3),
            (.unitMismatch(expected: .pan, found: .index), 4),
            (.notIntegral(1), 5), (.outOfRange(1, lower: 0, upper: 2), 6), (.aboveCeiling(1, ceiling: 0), 7)
        ]
        for (error, code) in valueErrors {
            #expect(F.byte(F.result(.refused(.command(.rejected(.invalidValue(error))))), at: 17) == code, "\(error)")
        }
        let stale: [(StaleDependency, UInt8)] = [(.connectionEpoch, 1), (.hostEpoch, 2),
                                                 (.generation(F.generationKey(.source, "g")), 3)]
        for (dependency, code) in stale {
            #expect(F.byte(F.result(.refused(.command(.stale(dependency)))), at: 16) == code, "\(dependency)")
        }
        let generation = F.result(.refused(.command(.stale(.generation(F.generationKey(.source, "g"))))))
        #expect(F.byte(generation, at: 17) == 4)
    }

    @Test func resyncReasonsMapAndKeepOnlyTheirOwnFields() {
        let reasons: [PeerResyncReason] = [
            .gap(expected: F.seq(2), found: F.seq(9)), .repeated(F.seq(3)),
            .unappliable(.emptyDelta), .snapshotRefused(.revisionRegressed)
        ]
        var codes = Set<UInt8>()
        for reason in reasons {
            let request = PeerResyncRequest(session: F.session(), lastApplied: F.seq(1), reason: reason)
            let wire = PeerResyncWireRequest(request)
            expectRoundTrip(.resync(wire), "\(reason)")
            if let code = F.byte(.resync(wire), at: 1 + F.sessionBytes.count + 8) {
                codes.insert(code)
            }
        }
        #expect(codes == [1, 2, 3, 4])
    }
}
