import Foundation
import Testing

@MainActor
struct UIAuditRunPreflightTests {
    private let runIDKey = "FLUXKLANG_AUDIT_RUN_ID"
    private let runID = "f767034a-c02c-47d7-a076-0110c8824c4e"
    private let flags = [
        "FLUXKLANG_ISOLATED_TESTING": "1",
        "FLUXKLANG_QUALIFY_APPLE_ROUTING": "0",
        "FLUXKLANG_RUN_APPLE_MODEL_TESTS": "0"
    ]
    private let orderedFlags: [UIAuditRunPreflight.Flag] = [
        .isolatedTesting, .qualifyAppleRouting, .runAppleModelTests
    ]

    private func runner(_ identity: String? = nil) -> [String: String] {
        var environment = flags
        environment[runIDKey] = identity ?? runID
        return environment
    }

    private func expectRefusal(
        _ expected: UIAuditRunPreflight.Refusal,
        runnerEnvironment: [String: String],
        appEnvironment: [String: String],
        appArguments: [String] = ["-ui-testing"]
    ) {
        let originalRunner = runnerEnvironment
        let originalApp = appEnvironment
        let originalArguments = appArguments
        let result = UIAuditRunPreflight.validate(
            runnerEnvironment: runnerEnvironment,
            appEnvironment: appEnvironment,
            appArguments: appArguments
        )
        switch result {
        case .failure(let refusal):
            #expect(refusal == expected)
        case .success:
            Issue.record("Expected preflight refusal")
        }
        var callbacks = 0
        do {
            try UIAuditRunPreflight.performValidatedLaunch(
                runnerEnvironment: runnerEnvironment,
                appEnvironment: appEnvironment,
                appArguments: appArguments
            ) { _ in
                callbacks += 1
            }
            Issue.record("Expected launch preflight refusal")
        } catch {
            #expect(error as? UIAuditRunPreflight.Refusal == expected)
        }
        #expect(callbacks == 0)
        #expect(runnerEnvironment == originalRunner)
        #expect(appEnvironment == originalApp)
        #expect(appArguments == originalArguments)
    }

    @Test func acceptsAllRFC4122VersionFourVariants() throws {
        for variant in ["8", "9", "a", "b"] {
            let identity = "f767034a-c02c-47d7-\(variant)076-0110c8824c4e"
            let configuration = try UIAuditRunPreflight.validate(
                runnerEnvironment: runner(identity), appEnvironment: flags, appArguments: ["-ui-testing"]
            ).get()
            #expect(configuration.runID == UUID(uuidString: identity))
            #expect(configuration.appEnvironment[runIDKey] == identity)
        }
    }

    @Test func refusesOtherVersionsAndVariants() {
        for version in ["0", "1", "2", "3", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"] {
            expectRefusal(
                .invalidRunnerRunID,
                runnerEnvironment: runner("f767034a-c02c-\(version)7d7-a076-0110c8824c4e"),
                appEnvironment: flags
            )
        }
        for variant in ["0", "1", "2", "3", "4", "5", "6", "7", "c", "d", "e", "f"] {
            expectRefusal(
                .invalidRunnerRunID,
                runnerEnvironment: runner("f767034a-c02c-47d7-\(variant)076-0110c8824c4e"),
                appEnvironment: flags
            )
        }
    }

    @Test func refusesMalformedAndNoncanonicalIdentities() {
        for identity in [
            "", "not-a-uuid", "f767034a-c02c-47d7-a076-0110c8824c4",
            "g767034a-c02c-47d7-a076-0110c8824c4e",
            runID.uppercased(), "F767034a-c02c-47d7-a076-0110c8824c4e",
            " \(runID)", "\(runID) ", "\t\(runID)", "\(runID)\n",
            runID.replacingOccurrences(of: "-", with: ""), "{\(runID)}", "urn:uuid:\(runID)"
        ] {
            expectRefusal(.invalidRunnerRunID, runnerEnvironment: runner(identity), appEnvironment: flags)
        }
    }

    @Test func refusesEachMissingOrWrongFlagInBothDomains() {
        for flag in orderedFlags {
            for value: String? in [nil, "", "true", "false", "01", "00", " 1", "0 ", "1\n", "0\n", "2",
                                  flags[flag.rawValue] == "1" ? "0" : "1"] {
                var invalidRunner = runner()
                invalidRunner[flag.rawValue] = value
                expectRefusal(
                    .invalidFlag(domain: .runner, flag: flag),
                    runnerEnvironment: invalidRunner, appEnvironment: flags
                )
                var invalidApp = flags
                invalidApp[flag.rawValue] = value
                expectRefusal(
                    .invalidFlag(domain: .app, flag: flag),
                    runnerEnvironment: runner(), appEnvironment: invalidApp
                )
            }
        }
    }

    @Test func requiresExactArgumentElement() {
        for arguments in [
            [], ["-ui-testing=1"], ["prefix-ui-testing"], ["-UI-TESTING"],
            [" -ui-testing"], ["-ui-testing "], ["-ui-testing\n"], ["app -ui-testing"],
            ["-ui", "-testing"]
        ] {
            expectRefusal(
                .missingUITestingArgument, runnerEnvironment: runner(),
                appEnvironment: flags, appArguments: arguments
            )
        }
    }

    @Test func preservesArgumentOrderUnrelatedValuesAndDuplicates() throws {
        for arguments in [
            ["-ui-testing", "--other", "value"],
            ["--other", "-ui-testing", "value"],
            ["--other", "value", "-ui-testing"],
            ["-ui-testing", "", "--other", "-ui-testing", "-ui-testing=1", "value"]
        ] {
            var callbacks = 0
            try UIAuditRunPreflight.performValidatedLaunch(
                runnerEnvironment: runner(), appEnvironment: flags, appArguments: arguments
            ) { configuration in
                callbacks += 1
                #expect(configuration.appArguments == arguments)
            }
            #expect(callbacks == 1)
        }
    }

    @Test func forwardsExactIdentityAndCopiesOnlyIntendedAppValues() throws {
        for existingIdentity: String? in [nil, runID] {
            var runnerEnvironment = runner()
            runnerEnvironment["RUNNER_ONLY"] = "do not forward"
            var appEnvironment = flags
            appEnvironment[runIDKey] = existingIdentity
            appEnvironment["APP_ONLY"] = " preserve whitespace \n"
            appEnvironment["EMPTY"] = ""
            var arguments = ["--unrelated", "-ui-testing", "", "-ui-testing", "value"]
            let originalRunner = runnerEnvironment
            let originalApp = appEnvironment
            let originalArguments = arguments
            var expectedApp = originalApp
            expectedApp[runIDKey] = runID
            var callbacks = 0
            var received: UIAuditRunPreflight.ValidatedLaunchConfiguration?
            try UIAuditRunPreflight.performValidatedLaunch(
                runnerEnvironment: runnerEnvironment, appEnvironment: appEnvironment, appArguments: arguments
            ) { configuration in
                callbacks += 1
                received = configuration
                #expect(configuration.runID == UUID(uuidString: runID))
                #expect(configuration.appEnvironment == expectedApp)
                #expect(configuration.appArguments == originalArguments)
            }
            #expect(callbacks == 1)
            let configuration = try #require(received)
            #expect(configuration.runID == UUID(uuidString: runID))
            #expect(configuration.appEnvironment == expectedApp)
            #expect(configuration.appArguments == originalArguments)
            #expect(runnerEnvironment == originalRunner)
            #expect(appEnvironment == originalApp)
            #expect(arguments == originalArguments)
            runnerEnvironment[runIDKey] = "changed"
            appEnvironment["APP_ONLY"] = "changed"
            arguments.append("changed")
            #expect(configuration.appEnvironment == expectedApp)
            #expect(configuration.appArguments == originalArguments)
        }
    }

    @Test func propagatesCallbackErrorWithoutRetry() {
        final class CallbackError: Error {}
        let sentinel = CallbackError()
        var callbacks = 0
        do {
            try UIAuditRunPreflight.performValidatedLaunch(
                runnerEnvironment: runner(), appEnvironment: flags, appArguments: ["-ui-testing"]
            ) { _ in
                callbacks += 1
                throw sentinel
            }
            Issue.record("Expected callback error")
        } catch {
            #expect((error as? CallbackError) === sentinel)
        }
        #expect(callbacks == 1)
    }

    @Test func refusesEveryConflictingAppIdentityWithoutRepair() {
        for identity in [
            "", "not-a-uuid", "4ad230c8-19f8-4d53-a673-63075124540a",
            runID.uppercased(), "F767034a-c02c-47d7-a076-0110c8824c4e",
            " \(runID)", "\(runID)\n", "{\(runID)}", "urn:uuid:\(runID)",
            runID.replacingOccurrences(of: "-", with: "")
        ] {
            var appEnvironment = flags
            appEnvironment[runIDKey] = identity
            expectRefusal(
                .conflictingAppRunID, runnerEnvironment: runner(), appEnvironment: appEnvironment
            )
        }
    }

    @Test func firstRefusalFollowsFixedOrderWithoutRepairingLaterConditions() throws {
        var runnerEnvironment: [String: String] = [:]
        var appEnvironment = [runIDKey: "conflicting"]
        expectRefusal(
            .missingRunnerRunID, runnerEnvironment: runnerEnvironment,
            appEnvironment: appEnvironment, appArguments: []
        )
        runnerEnvironment[runIDKey] = "invalid"
        expectRefusal(
            .invalidRunnerRunID, runnerEnvironment: runnerEnvironment,
            appEnvironment: appEnvironment, appArguments: []
        )
        runnerEnvironment[runIDKey] = runID
        for flag in orderedFlags {
            for value: String? in [nil, "wrong"] {
                runnerEnvironment[flag.rawValue] = value
                expectRefusal(
                    .invalidFlag(domain: .runner, flag: flag), runnerEnvironment: runnerEnvironment,
                    appEnvironment: appEnvironment, appArguments: []
                )
            }
            runnerEnvironment[flag.rawValue] = flags[flag.rawValue]
        }
        for flag in orderedFlags {
            for value: String? in [nil, "wrong"] {
                appEnvironment[flag.rawValue] = value
                expectRefusal(
                    .invalidFlag(domain: .app, flag: flag), runnerEnvironment: runnerEnvironment,
                    appEnvironment: appEnvironment, appArguments: []
                )
            }
            appEnvironment[flag.rawValue] = flags[flag.rawValue]
        }
        expectRefusal(
            .missingUITestingArgument, runnerEnvironment: runnerEnvironment,
            appEnvironment: appEnvironment, appArguments: []
        )
        expectRefusal(
            .conflictingAppRunID, runnerEnvironment: runnerEnvironment, appEnvironment: appEnvironment
        )
        appEnvironment[runIDKey] = runID
        let configuration = try UIAuditRunPreflight.validate(
            runnerEnvironment: runnerEnvironment, appEnvironment: appEnvironment, appArguments: ["-ui-testing"]
        ).get()
        #expect(configuration.appEnvironment == appEnvironment)
    }
}
