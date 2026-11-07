import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginHostNegotiationTests {
    private static func firstLedger(_ attempts: Int) throws -> ReprepareLedger {
        ReprepareLedger(budget: try ReprepareBudget(maximumAttempts: attempts))
    }

    private static func complete(_ ledger: ReprepareLedger, _ succeeded: Bool) throws -> ReprepareTransition {
        let token = try #require(ledger.pendingToken)
        return try ledger.recordingPreparation(token, succeeded: succeeded)
    }

    @Test("reprepare a token carried over from a replaced ledger is refused by the restarted ledger")
    func reprepareRestartedLedgerRefusesTheReplacedLedgersToken() throws {
        let preparing = try Self.firstLedger(1).observing(.format).ledger
        let old = try #require(preparing.pendingToken)
        let replaced = preparing.observing(.format).ledger
        #expect(replaced.status == .silenced)
        let restarted = replaced.restarted()
        #expect(restarted.status == .rendering)
        let before = restarted
        for succeeded in [true, false] {
            #expect(throws: ReprepareFault.notPreparing(.rendering)) {
                try before.recordingPreparation(old, succeeded: succeeded)
            }
        }
        #expect(restarted == before)
        let started = restarted.observing(.busLayout).ledger
        let silenced = started.observing(.busLayout).ledger
        #expect(silenced.status == .silenced)
        let frozen = silenced
        for succeeded in [true, false] {
            #expect(throws: ReprepareFault.notPreparing(.silenced)) {
                try frozen.recordingPreparation(old, succeeded: succeeded)
            }
        }
        #expect(silenced == frozen)
    }

    @Test("reprepare after a restart a new decision issues a new token and the replaced ledger's token is superseded")
    func reprepareRestartedLedgerIssuesANewTokenAndSupersedesTheOldOne() throws {
        let preparing = try Self.firstLedger(2).observing(.format).ledger
        let old = try #require(preparing.pendingToken)
        #expect(preparing.issued == 1)
        let transition = preparing.restarted().observing(.format)
        #expect(transition.decision == .reprepare(attempt: 1))
        #expect(transition.ledger.issued == 2)
        let fresh = try #require(transition.ledger.pendingToken)
        #expect(fresh != old)
        let before = transition.ledger
        for succeeded in [true, false] {
            #expect(throws: ReprepareFault.superseded(presented: old, current: fresh)) {
                try before.recordingPreparation(old, succeeded: succeeded)
            }
        }
        #expect(transition.ledger == before)
        let resumed = try before.recordingPreparation(fresh, succeeded: true)
        #expect(resumed.decision == .resume)
        #expect(resumed.ledger.issued == 2)
    }

    @Test("reprepare tokens never repeat across chained restarts and supersessions")
    func reprepareTokensNeverRepeatAcrossRestarts() throws {
        var ledger = try Self.firstLedger(2)
        var tokens: [ReprepareToken] = []
        for round in 1...25 {
            ledger = ledger.observing(.format).ledger
            tokens.append(try #require(ledger.pendingToken))
            ledger = ledger.observing(.sampleRate).ledger
            tokens.append(try #require(ledger.pendingToken))
            if round.isMultiple(of: 2) { ledger = try Self.complete(ledger, true).ledger }
            ledger = ledger.restarted()
            #expect(ledger.issued == round * 2)
            #expect(ledger.status == .rendering)
        }
        #expect(tokens.count == 50)
        #expect(Set(tokens).count == 50)
    }

    @Test("reprepare restarted keeps the budget and the issued count and zeroes the attempts from every status")
    func reprepareRestartedKeepsTheBudgetFromEveryStatus() throws {
        for maximum in [1, 3, 8] {
            let rendering = try Self.firstLedger(maximum)
            let preparing = rendering.observing(.format).ledger
            var silenced = preparing
            for _ in 0..<maximum { silenced = silenced.observing(.format).ledger }
            #expect(preparing.status == .preparing)
            #expect(silenced.status == .silenced)
            let cases = [(rendering, 0), (preparing, 1), (silenced, maximum)]
            for (ledger, issued) in cases {
                let successor = ledger.restarted()
                #expect(successor.budget.maximumAttempts == maximum)
                #expect(successor.status == .rendering)
                #expect(successor.attempts == 0)
                #expect(successor.pendingToken == nil)
                #expect(successor.issued == issued)
            }
        }
    }

    private struct TokenWalk {
        var ledger: ReprepareLedger
        var issued: [ReprepareToken] = []
        var staleChecks = 0
        var violations = 0

        mutating func presentStaleTokens() {
            for token in issued where token != ledger.pendingToken {
                for succeeded in [true, false] {
                    staleChecks += 1
                    do {
                        _ = try ledger.recordingPreparation(token, succeeded: succeeded)
                        violations += 1
                    } catch {
                        let fault: ReprepareFault = error
                        var wanted = ReprepareFault.notPreparing(ledger.status)
                        if let current = ledger.pendingToken {
                            wanted = .superseded(presented: token, current: current)
                        }
                        violations += fault == wanted ? 0 : 1
                    }
                }
            }
        }

        mutating func apply(_ operation: Int) {
            let before = ledger
            presentStaleTokens()
            violations += ledger == before ? 0 : 1
            let changes = RenderLiveChange.allCases
            if operation < changes.count {
                ledger = ledger.observing(changes[operation]).ledger
            } else if operation == changes.count {
                ledger = ledger.restarted()
            } else if let token = ledger.pendingToken,
                      let next = try? ledger.recordingPreparation(token, succeeded: operation == changes.count + 1) {
                ledger = next.ledger
            }
            if let token = ledger.pendingToken, !issued.contains(token) { issued.append(token) }
        }
    }

    @Test("reprepare every reachable state refuses every earlier token and stays unchanged")
    func reprepareWalkRefusesEveryStaleTokenOverReachableStates() throws {
        let operations = RenderLiveChange.allCases.count + 3
        var staleChecks = 0
        for length in 1...5 {
            var total = 1
            for _ in 0..<length { total *= operations }
            for code in 0..<total {
                var walk = TokenWalk(ledger: try Self.firstLedger(2))
                var remaining = code
                for _ in 0..<length {
                    walk.apply(remaining % operations)
                    remaining /= operations
                }
                #expect(walk.violations == 0)
                staleChecks += walk.staleChecks
            }
        }
        #expect(staleChecks > 0)
    }
}
