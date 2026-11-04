import Foundation

/// Supplied-value consistency only; not launch authority, provenance, delivery, or readiness.
enum UIAuditRunPreflight {
    struct ValidatedLaunchConfiguration {
        let runID: UUID
        let appEnvironment: [String: String]
        let appArguments: [String]
    }

    enum Domain {
        case runner, app
    }

    enum Flag: String {
        case isolatedTesting = "FLUXKLANG_ISOLATED_TESTING"
        case qualifyAppleRouting = "FLUXKLANG_QUALIFY_APPLE_ROUTING"
        case runAppleModelTests = "FLUXKLANG_RUN_APPLE_MODEL_TESTS"
    }

    enum Refusal: Error, Equatable {
        case missingRunnerRunID
        case invalidRunnerRunID
        /// Missing or unequal to the required literal.
        case invalidFlag(domain: Domain, flag: Flag)
        case missingUITestingArgument
        case conflictingAppRunID
    }

    private static let runIDKey = "FLUXKLANG_AUDIT_RUN_ID"
    private static let requiredFlags: [(Flag, String)] = [
        (.isolatedTesting, "1"),
        (.qualifyAppleRouting, "0"),
        (.runAppleModelTests, "0")
    ]

    /// Refusal precedes the callback; a callback error propagates without retry.
    @MainActor
    static func performValidatedLaunch(
        runnerEnvironment: [String: String],
        appEnvironment: [String: String],
        appArguments: [String],
        perform: @MainActor (ValidatedLaunchConfiguration) throws -> Void
    ) throws {
        let configuration = try validate(
            runnerEnvironment: runnerEnvironment,
            appEnvironment: appEnvironment,
            appArguments: appArguments
        ).get()
        try perform(configuration)
    }

    /// `appEnvironment` is the intended explicit launch dictionary, not raw target metadata.
    static func validate(
        runnerEnvironment: [String: String],
        appEnvironment: [String: String],
        appArguments: [String]
    ) -> Result<ValidatedLaunchConfiguration, Refusal> {
        guard let rawRunID = runnerEnvironment[runIDKey] else {
            return .failure(.missingRunnerRunID)
        }
        // Foundation parsing alone accepts spellings and UUID policies outside this contract.
        guard let runID = UUID(uuidString: rawRunID),
              runID.uuidString.lowercased() == rawRunID,
              runID.uuid.6 >> 4 == 4,
              runID.uuid.8 & 0xc0 == 0x80 else {
            return .failure(.invalidRunnerRunID)
        }
        for (flag, value) in requiredFlags where runnerEnvironment[flag.rawValue] != value {
            return .failure(.invalidFlag(domain: .runner, flag: flag))
        }
        for (flag, value) in requiredFlags where appEnvironment[flag.rawValue] != value {
            return .failure(.invalidFlag(domain: .app, flag: flag))
        }
        guard appArguments.contains("-ui-testing") else {
            return .failure(.missingUITestingArgument)
        }
        if let appRunID = appEnvironment[runIDKey], appRunID != rawRunID {
            return .failure(.conflictingAppRunID)
        }
        var launchEnvironment = appEnvironment
        launchEnvironment[runIDKey] = rawRunID
        return .success(ValidatedLaunchConfiguration(
            runID: runID,
            appEnvironment: launchEnvironment,
            appArguments: appArguments
        ))
    }
}
