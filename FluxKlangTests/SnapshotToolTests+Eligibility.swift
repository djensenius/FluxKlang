import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SnapshotToolTests {
    struct EligibilityRow {
        let userEnabled: Bool
        let modelReady: Bool
        let busy: Bool
        let providerIsCloud: Bool
        let expected: AssistantEligibility

        var facts: AssistantFacts {
            AssistantFacts(
            userEnabled: userEnabled, modelReady: modelReady, busy: busy, providerIsCloud: providerIsCloud
        )
        }
    }

    /// Typed out by hand: enabled, ready, busy, cloud, then the expected answer.
    static let eligibilityTable: [EligibilityRow] = [
        EligibilityRow(userEnabled: false, modelReady: false, busy: false, providerIsCloud: false, expected: .off),
        EligibilityRow(userEnabled: false, modelReady: false, busy: false, providerIsCloud: true, expected: .off),
        EligibilityRow(userEnabled: false, modelReady: false, busy: true, providerIsCloud: false, expected: .off),
        EligibilityRow(userEnabled: false, modelReady: false, busy: true, providerIsCloud: true, expected: .off),
        EligibilityRow(userEnabled: false, modelReady: true, busy: false, providerIsCloud: false, expected: .off),
        EligibilityRow(userEnabled: false, modelReady: true, busy: false, providerIsCloud: true, expected: .off),
        EligibilityRow(userEnabled: false, modelReady: true, busy: true, providerIsCloud: false, expected: .off),
        EligibilityRow(userEnabled: false, modelReady: true, busy: true, providerIsCloud: true, expected: .off),
        EligibilityRow(userEnabled: true, modelReady: false, busy: false, providerIsCloud: false,
                       expected: .notEligible(.modelUnavailable)),
        EligibilityRow(userEnabled: true, modelReady: false, busy: false, providerIsCloud: true,
                       expected: .notEligible(.cloudProvider)),
        EligibilityRow(userEnabled: true, modelReady: false, busy: true, providerIsCloud: false,
                       expected: .notEligible(.modelUnavailable)),
        EligibilityRow(userEnabled: true, modelReady: false, busy: true, providerIsCloud: true,
                       expected: .notEligible(.cloudProvider)),
        EligibilityRow(userEnabled: true, modelReady: true, busy: false, providerIsCloud: false,
                       expected: .eligible),
        EligibilityRow(userEnabled: true, modelReady: true, busy: false, providerIsCloud: true,
                       expected: .notEligible(.cloudProvider)),
        EligibilityRow(userEnabled: true, modelReady: true, busy: true, providerIsCloud: false, expected: .busy),
        EligibilityRow(userEnabled: true, modelReady: true, busy: true, providerIsCloud: true,
                       expected: .notEligible(.cloudProvider))
    ]

    @Test func theSixteenFactCombinationsGiveTheTypedOutExpectedAnswers() {
        #expect(Self.eligibilityTable.count == 16)
        let distinct = Set(Self.eligibilityTable.map { [$0.userEnabled, $0.modelReady, $0.busy, $0.providerIsCloud] })
        #expect(distinct.count == 16)
        for row in Self.eligibilityTable {
            #expect(AssistantEligibility.evaluate(row.facts) == row.expected, "\(row.facts)")
        }
    }

    @Test func aCloudProviderIsNeverEligibleOrBusyWhateverTheOtherThreeFlagsAre() {
        for enabled in [false, true] {
            for ready in [false, true] {
                for busy in [false, true] {
                    let facts = AssistantFacts(
                        userEnabled: enabled, modelReady: ready, busy: busy, providerIsCloud: true
                    )
                    let answer = AssistantEligibility.evaluate(facts)
                    #expect(answer != .eligible && answer != .busy, "\(facts)")
                }
            }
        }
    }

    @Test func aDisabledAssistantIsOffEvenWithACloudProviderAndAnUnreadyModel() {
        let facts = AssistantFacts(userEnabled: false, modelReady: false, busy: true, providerIsCloud: true)
        #expect(AssistantEligibility.evaluate(facts) == .off)
    }

    @Test func aCloudProviderIsReportedBeforeAnUnreadyModel() {
        let facts = AssistantFacts(userEnabled: true, modelReady: false, busy: false, providerIsCloud: true)
        #expect(AssistantEligibility.evaluate(facts) == .notEligible(.cloudProvider))
    }

    @Test func anUnreadyModelIsReportedBeforeABusyAssistant() {
        let facts = AssistantFacts(userEnabled: true, modelReady: false, busy: true, providerIsCloud: false)
        #expect(AssistantEligibility.evaluate(facts) == .notEligible(.modelUnavailable))
    }

    @Test func aCloudProviderIsReportedBeforeABusyAssistant() {
        let facts = AssistantFacts(userEnabled: true, modelReady: true, busy: true, providerIsCloud: true)
        #expect(AssistantEligibility.evaluate(facts) == .notEligible(.cloudProvider))
    }

    @Test func aDisabledAssistantIsOffBeforeAnUnreadyModelAndBeforeBusy() {
        let unready = AssistantFacts(userEnabled: false, modelReady: false, busy: false, providerIsCloud: false)
        let busy = AssistantFacts(userEnabled: false, modelReady: true, busy: true, providerIsCloud: false)
        #expect(AssistantEligibility.evaluate(unready) == .off)
        #expect(AssistantEligibility.evaluate(busy) == .off)
    }
}
