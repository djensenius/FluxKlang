//
//  SetupFlowScreen+Text.swift
//  FluxKlang
//
//  The fixed sentences and labels of the setup flow screen. English text without a payload: no number, rig id or
//  device name is spelled into a sentence (the view reads those from the refusal itself). No sentence says that a
//  device is on, that a tone plays or that a route is applied.
//

enum SetupFlowScreenText {
    static let mutedNote = "Lost or muted devices stay muted. Setup makes no sound."

    static func headline(for phase: SetupFlowPhase) -> String {
        switch phase {
        case .running(let step):
            return runningHeadline(step)
        case .suspended:
            return "Setup is paused. Reopen it or stay manual."
        case .ended(let ending):
            return endedHeadline(ending)
        }
    }

    private static func runningHeadline(_ step: SetupFlowStep) -> String {
        switch step {
        case .identify:
            return "Step 1 of 4: identify your audio interface."
        case .map:
            return "Step 2 of 4: map the interface to your roles."
        case .review:
            return "Step 3 of 4: review the Home pane and the runtime map pane."
        case .decide:
            return "Step 4 of 4: apply the setup or stay manual."
        }
    }

    private static func endedHeadline(_ ending: SetupFlowEnding) -> String {
        switch ending {
        case .manual:
            return "Setup ended. Manual and remote control stay available."
        case .applyRequested:
            return "Setup ended with a request to apply the chosen rig."
        }
    }

    static func manualSentence(for manual: SetupFlowScreenManual) -> String {
        switch manual {
        case .offered:
            return "Stay manual to use manual or remote control without this setup."
        case .active:
            return "Manual and remote control are in use."
        case .notOffered:
            return "Manual mode is not part of this ending."
        }
    }

    static func label(for event: SetupFlowEvent) -> String {
        switch event {
        case .next:
            return "Next"
        case .back:
            return "Back"
        case .chooseRig:
            return "Choose this rig"
        case .acknowledge(.home):
            return "Confirm the Home pane"
        case .acknowledge(.runtimeMap):
            return "Confirm the runtime map pane"
        case .requestApply:
            return "Apply"
        case .stayManual:
            return "Stay manual"
        case .cancel:
            return "Pause setup"
        case .reopen:
            return "Reopen setup"
        }
    }

    /// The sentence of a refusal. Four small switches, each naming the refusals of the others in one `nil` arm.
    static func sentence(for refusal: SetupFlowRefusal) -> String {
        // The four switches are exhaustive, so the empty fallback is unreachable.
        buildSentence(refusal) ?? flowSentence(refusal) ?? gateSentence(refusal) ?? paneSentence(refusal) ?? ""
    }

    /// The refusals that `SetupFlowFacts.make` gives; the reducer never throws them.
    private static func buildSentence(_ refusal: SetupFlowRefusal) -> String? {
        switch refusal {
        case .tooManyRigs:
            return "Too many rigs are offered."
        case .factOutOfRange:
            return "A setup fact is out of range."
        case .duplicateRig:
            return "The same rig is offered twice."
        case .flowEnded, .suspended, .notSuspended, .noNextStep, .noPreviousStep, .wrongStep, .rigNotOffered,
             .permissionNotGranted, .noPresentDevice, .rigNotChosen, .rolesUndecided, .paneNotReviewed:
            return nil
        }
    }

    private static func flowSentence(_ refusal: SetupFlowRefusal) -> String? {
        switch refusal {
        case .flowEnded:
            return "Setup has ended."
        case .suspended:
            return "Setup is paused."
        case .notSuspended:
            return "Setup is already running."
        case .noNextStep:
            return "This is the last step."
        case .noPreviousStep:
            return "This is the first step."
        case .wrongStep:
            return "That action belongs to another step."
        case .tooManyRigs, .factOutOfRange, .duplicateRig, .rigNotOffered, .permissionNotGranted, .noPresentDevice,
             .rigNotChosen, .rolesUndecided, .paneNotReviewed:
            return nil
        }
    }

    private static func gateSentence(_ refusal: SetupFlowRefusal) -> String? {
        switch refusal {
        case .rigNotOffered:
            return "The chosen rig is not offered."
        case .permissionNotGranted:
            return "Audio interface access is not granted."
        case .noPresentDevice:
            return "No audio interface is present."
        case .rigNotChosen:
            return "Choose a rig first."
        case .rolesUndecided:
            return "Some roles still need a decision."
        case .tooManyRigs, .factOutOfRange, .duplicateRig, .flowEnded, .suspended, .notSuspended, .noNextStep,
             .noPreviousStep, .wrongStep, .paneNotReviewed:
            return nil
        }
    }

    private static func paneSentence(_ refusal: SetupFlowRefusal) -> String? {
        switch refusal {
        case .paneNotReviewed(.home):
            return "Confirm the Home pane again."
        case .paneNotReviewed(.runtimeMap):
            return "Confirm the runtime map pane again."
        case .tooManyRigs, .factOutOfRange, .duplicateRig, .flowEnded, .suspended, .notSuspended, .noNextStep,
             .noPreviousStep, .wrongStep, .rigNotOffered, .permissionNotGranted, .noPresentDevice, .rigNotChosen,
             .rolesUndecided:
            return nil
        }
    }
}
