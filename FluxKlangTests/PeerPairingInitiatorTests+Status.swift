import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private func isEncodable<T>(_: T.Type) -> Bool { false }
private func isEncodable<T: Encodable>(_: T.Type) -> Bool { true }
private func isDecodable<T>(_: T.Type) -> Bool { false }
private func isDecodable<T: Decodable>(_: T.Type) -> Bool { true }
private func runtimeCodable(_ type: Any.Type) -> Bool { type is any Encodable.Type || type is any Decodable.Type }

extension PeerPairingInitiatorTests {
    static let productionNames = [
        "PeerPairingInitiator.swift", "PeerPairingStatus.swift", "PeerPairingPayload.swift",
        "PeerPairingLabelRule.swift"
    ]

    /// The directory holding the production files: next to the checkout's `Shared`, or in the mirror package.
    static var productionDirectory: URL? {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            tests.deletingLastPathComponent().appendingPathComponent("Shared/Peer/Pairing"),
            tests.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/FluxKlang/Shared/Peer/Pairing")
        ]
        return candidates.first { candidate in
            productionNames.allSatisfy {
                FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path)
            }
        }
    }

    /// The conformance and trust-API words found in `text` outside `//` comments. A textual check only.
    static func textualFindings(in text: String) -> [String] {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.components(separatedBy: "//").first ?? ""
        }.joined(separator: "\n")
        return ["Codable", "Encodable", "Decodable", "NSCoding", "PeerGrantSet", ".pair(", "PeerTrustStore()"]
            .filter { code.contains($0) }
    }

    // MARK: Status values

    @Test("Only paired, denied and timed out are terminal")
    func statusIsTerminalOnlyForPairedDeniedAndTimedOut() throws {
        let prompt = try shownPromptForStatusTests()
        let open: [PeerPairingStatus] = [.idle, .committed, .awaitingHostNonce, .showingCode(prompt),
                                         .awaitingHostDecision]
        let ended: [PeerPairingStatus] = [.paired, .denied(.codesDidNotMatch), .denied(.hostDenied),
                                          .denied(.nonceReplay), .timedOut]
        #expect(open.allSatisfy { !$0.isTerminal })
        #expect(ended.allSatisfy { $0.isTerminal })
    }

    @Test("The status exposes the prompt and its code only while it is shown")
    func statusCodeIsPresentOnlyWhileTheCodeIsShown() throws {
        let prompt = try shownPromptForStatusTests()
        #expect(PeerPairingStatus.showingCode(prompt).code == prompt.code)
        #expect(PeerPairingStatus.showingCode(prompt).prompt == prompt)
        let others: [PeerPairingStatus] = [.idle, .committed, .awaitingHostNonce, .awaitingHostDecision, .paired,
                                           .denied(.hostDenied), .timedOut]
        #expect(others.allSatisfy { $0.code == nil && $0.prompt == nil })
    }

    private func shownPromptForStatusTests() throws -> PeerInitiatorPrompt {
        var initiator = try self.initiator(at: .awaitingHostNonce)
        return try initiator.receiveHostNonce(Self.nonce(2), now: start)
    }

    @Test("The status follows each step and shows exactly the code the host nonce produced")
    func statusWalkReportsEachStepAndTheReturnedCode() throws {
        var initiator = PeerPairingInitiator()
        #expect(initiator.status == .idle)
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(1), now: start)
        #expect(initiator.status == .committed)
        try initiator.requestSent(now: start)
        #expect(initiator.status == .awaitingHostNonce)
        let prompt = try initiator.receiveHostNonce(Self.nonce(2), now: start)
        let code = prompt.code
        #expect(initiator.status == .showingCode(prompt) && initiator.status.code == code)
        #expect(prompt.attempt == Self.firstAttempt && initiator.status.prompt == prompt)
        #expect(code.digits.count == 6 && code.digits.allSatisfy(\.isNumber))
        try initiator.userConfirmed(codesMatch: true, for: prompt.attempt, now: start)
        #expect(initiator.status == .awaitingHostDecision)
        #expect(initiator.tick(now: start + .milliseconds(59_999)) == .awaitingHostDecision)
        _ = initiator.revealToSend(now: start)
        try initiator.hostOutcome(approved: true, now: start)
        #expect(initiator.status == .paired)
    }

    @Test("Each way an attempt is denied has its own reason, and a timeout is not a denial")
    func statusDeniedReasonsNameTheirOwnCause() throws {
        var codes = try initiator(at: .showing)
        try codes.userConfirmed(codesMatch: false, for: Self.firstAttempt, now: start)
        var host = try initiator(at: .awaitingDecision)
        try host.hostOutcome(approved: false, now: start)
        var replay = try initiator(at: .awaitingHostNonce)
        #expect(refusal(of: .host(Self.nonce(1)), on: &replay, at: start) == .nonceReplay)
        let timedOut = try initiator(at: .timedOut)
        #expect(codes.status == .denied(.codesDidNotMatch) && host.status == .denied(.hostDenied))
        #expect(replay.status == .denied(.nonceReplay) && timedOut.status == .timedOut)
    }

    // MARK: Out of phase

    @Test("Every step out of phase is refused as unexpected, a start as busy, and changes nothing")
    func initiatorStepsOutOfPhaseAreRefusedAndChangeNothing() throws {
        // A host denial is also accepted while the host's prompt can be up, before the decision phase.
        let denialAccepted: Set<Stage> = [.awaitingHostNonce, .showing]
        let allowed: [Stage: [String]] = [
            .idle: ["start"], .committed: ["sent"], .awaitingHostNonce: ["host"], .showing: ["confirm"],
            .awaitingDecision: ["outcome"], .paired: ["start"], .denied: ["start"], .timedOut: ["start"]
        ]
        #expect(allowed.count == Stage.allCases.count)
        for stage in Stage.allCases {
            let kinds = allowed[stage] ?? []
            for step in allSteps() {
                var initiator = try self.initiator(at: stage)
                let before = initiator
                var denial = false
                if case .outcome(false) = step { denial = denialAccepted.contains(stage) }
                if case .outcome(true) = step, stage == .awaitingDecision {
                    #expect(refusal(of: step, on: &initiator, at: start) == .nonceNotRevealed, "\(stage) approval")
                    #expect(initiator == before, "\(stage) approval")
                } else if kinds.contains(step.kind) || denial {
                    #expect(refusal(of: step, on: &initiator, at: start) == nil, "\(stage) \(step.kind)")
                    #expect(initiator != before, "\(stage) \(step.kind)")
                } else {
                    // No attempt was issued while idle, so a confirmation naming attempt 1 is stale there.
                    let outOfPhase: PeerInitiatorError = stage == .idle && step.kind == "confirm"
                        ? .staleAttempt : .unexpectedStep
                    let expected: PeerInitiatorError = step.kind == "start" ? .busy : outOfPhase
                    #expect(refusal(of: step, on: &initiator, at: start) == expected, "\(stage) \(step.kind)")
                    #expect(initiator == before, "\(stage) \(step.kind)")
                }
            }
        }
    }

    @Test("A host denial ends the attempt as denied in each phase where its prompt can be up, and nothing follows")
    func initiatorHostDenialEndsTheAttemptInEveryPhaseWhereThePromptCanBeUp() throws {
        let reachable: [(stage: Stage, revealed: Bool)] = [
            (.awaitingHostNonce, false), (.showing, false), (.showing, true),
            (.awaitingDecision, false), (.awaitingDecision, true)
        ]
        for (stage, revealed) in reachable {
            var initiator = try self.initiator(at: stage, revealed: revealed)
            if stage == .showing, revealed { #expect(initiator.revealToSend(now: start) != nil) }
            try initiator.hostOutcome(approved: false, now: start)
            #expect(initiator.status == .denied(.hostDenied), "\(stage) revealed \(revealed)")
            #expect(initiator.revealToSend(now: start) == nil, "\(stage) revealed \(revealed)")
            let ended = initiator
            for step in allSteps() where step.kind != "start" {
                #expect(refusal(of: step, on: &initiator, at: start) == .unexpectedStep, "\(stage) \(step.kind)")
            }
            #expect(initiator == ended, "\(stage) revealed \(revealed)")
        }
    }

    @Test("A host approval before the decision phase is refused as unexpected and changes nothing")
    func initiatorHostApprovalBeforeTheDecisionPhaseIsRefusedAndChangesNothing() throws {
        let reachable: [(stage: Stage, revealed: Bool)] = [
            (.awaitingHostNonce, false), (.showing, false), (.showing, true)
        ]
        for (stage, revealed) in reachable {
            var initiator = try self.initiator(at: stage)
            if stage == .showing, revealed { #expect(initiator.revealToSend(now: start) != nil) }
            let before = initiator
            let refused = refusal(of: .outcome(true), on: &initiator, at: start)
            #expect(refused == .unexpectedStep, "\(stage) revealed \(revealed)")
            #expect(initiator == before, "\(stage) revealed \(revealed)")
        }
    }

    // MARK: Secrecy and storage

    @Test("Description, debug description and dump show the phase name only, never the nonce bytes or the code")
    func initiatorDescriptionsNeverShowTheNonceBytes() throws {
        let leak = ["90, 90", "PeerNonce", "bytes"]
        let nonceDump = String(reflecting: Self.nonce(1))
        #expect(leak.allSatisfy { nonceDump.contains($0) }, "the leak probe must see a nonce when one is printed")
        let shown = try initiator(at: .showing)
        let digits = try #require(shown.status.code).digits
        var out = ""
        for stage in [Stage.committed, .showing, .awaitingDecision, .paired] {
            let initiator = try self.initiator(at: stage, revealed: true)
            out += String(describing: initiator) + String(reflecting: initiator) + "\(initiator)"
            dump(initiator, to: &out)
        }
        #expect(out.contains("PeerPairingInitiator(showingCode)") && out.contains("phase"))
        #expect(!leak.contains { out.contains($0) })
        #expect(!out.contains(digits))
    }

    @Test("None of the pairing value types is Encodable or Decodable at compile time or at run time")
    func initiatorStatusAndPayloadTypesAreNotCodable() {
        let compileTime = [
            isEncodable(PeerPairingInitiator.self), isDecodable(PeerPairingInitiator.self),
            isEncodable(PeerPairingStatus.self), isDecodable(PeerPairingStatus.self),
            isEncodable(PeerPairingDeniedReason.self), isDecodable(PeerPairingDeniedReason.self),
            isEncodable(PeerPairingPayload.self), isDecodable(PeerPairingPayload.self),
            isEncodable(PeerPairingAttemptSpec.self), isDecodable(PeerPairingAttemptSpec.self)
        ]
        #expect(!compileTime.contains(true))
        let types: [Any.Type] = [PeerPairingInitiator.self, PeerPairingStatus.self, PeerPairingDeniedReason.self,
                                 PeerPairingPayload.self, PeerPairingAttemptSpec.self]
        #expect(!types.contains(where: runtimeCodable))
        #expect(isEncodable(String.self) && runtimeCodable(String.self), "the probes can see a Codable type")
    }

    @Test(.enabled(if: PeerPairingInitiatorTests.productionDirectory != nil,
                   "the production sources are not next to the tests"))
    func productionSourcesNameNoCodableConformanceGrantSetOrStorePairingTextually() throws {
        let directory = try #require(Self.productionDirectory)
        for name in Self.productionNames {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(Self.textualFindings(in: text).isEmpty, "\(name)")
        }
    }

    @Test("The textual scanner flags conformances and trust writes outside comments and ignores comments")
    func textualScannerFlagsConformancesAndIgnoresComments() {
        #expect(Self.textualFindings(in: "struct A: Hashable, Codable {}") == ["Codable"])
        #expect(Self.textualFindings(in: "enum B: Encodable {}") == ["Encodable"])
        #expect(Self.textualFindings(in: "extension C: Decodable {}") == ["Decodable"])
        #expect(Self.textualFindings(in: "let g = try PeerGrantSet(x)") == ["PeerGrantSet"])
        #expect(Self.textualFindings(in: "try store.pair(a)") == [".pair("])
        #expect(Self.textualFindings(in: "// Codable PeerGrantSet\nlet x = 1 // .pair(").isEmpty)
    }
}
