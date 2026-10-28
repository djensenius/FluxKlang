import AppIntents
import Foundation

/// A discoverable Siri/Shortcuts entry point, not interception of arbitrary global Siri utterances.
struct AskFluxKlangIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask FluxKlang"
    static let description = IntentDescription(
        "Bring a request to FluxKlang. Tap Send in the app for interpretation and review; no WING changes are made."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Request", requestValueDialog: "What would you like to review in FluxKlang?")
    var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("Review \(\.$request) in FluxKlang")
    }

    init() {}

    init(request: String) {
        self.request = request
    }

    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = SiriAssistantRequestAction.stage(request: request, model: AppModel.shared)
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

@MainActor
enum SiriAssistantRequestAction {
    static func stage(request: String, model: AppModel) -> String {
        model.section = .assistant
        return model.assistantChat.stageSiriRequest(request)
    }
}
