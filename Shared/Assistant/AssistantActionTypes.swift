import Foundation

/// Value-only input: current submission, never conversation history or an execution capability.
struct AssistantActionInterpretationRequest: Sendable {
    let submissionID: UUID
    let text: String
    let liveContext: AssistantLiveWingContext

    init(submissionID: UUID = UUID(), text: String, liveContext: AssistantLiveWingContext = .unavailable) {
        self.submissionID = submissionID
        self.text = text
        self.liveContext = liveContext
    }
}

enum AssistantActionInterpreterAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// Implementations must be tool-free and input-only. Output is untrusted intent, not a plan or permission.
protocol AssistantActionInterpreting: Sendable {
    func availability() async -> AssistantActionInterpreterAvailability
    func interpret(_ request: AssistantActionInterpretationRequest) async throws -> AssistantActionInterpretation
}

enum AssistantActionInterpretation: Equatable, Sendable {
    /// Forward the unchanged submission to the ordinary read-only answer pipeline.
    case answer
    case clarification(String)
    case proposal(AssistantActionIntent)
}

struct AssistantActionIntent: Equatable, Sendable {
    enum Action: String, Sendable, CaseIterable {
        case lower, raise, setDB, setFaderPercent, mute, unmute
    }

    /// Substrings copied from this submission, checked independently of model generation.
    struct Evidence: Equatable, Sendable {
        let target: String
        let action: String?
        let amount: String?
        let add: String?
    }

    let targetMention: String
    let action: Action?
    /// Positive magnitude for lower/raise; signed dB for setDB; 0...100 fader travel for percent.
    /// Missing relative amount may produce a visibly suggested 3 dB preview, never an automatic SET.
    let amount: Double?
    let addToStudio: Bool
    let evidence: Evidence
}

/// Display evidence only; even exact matches must go through preparation and explicit confirmation.
struct AssistantActionCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let members: [AssistantActionChannelIdentity]
    let pairStripID: UUID?
    let match: Match

    enum Match: String, Hashable, Sendable { case exact, similar, explicitIdentity, savedLink }
}

struct AssistantActionChannelIdentity: Hashable, Sendable {
    let node: WingNodeRef
    let label: String
    let sourceGroup: String?
    let sourceIndex: Int?
    let equipmentID: Equipment.ID?
}

struct AssistantActionMemberEvidence: Hashable, Sendable {
    let identity: AssistantActionChannelIdentity
    let position: Float
    let muted: Bool
}

struct AssistantActionTargetEvidence: Hashable, Sendable {
    let sessionID: UUID
    let members: [AssistantActionMemberEvidence]
    /// Only a non-overlapping, existing saved layout pair can authorize a reviewed stereo unit.
    let pairStripID: UUID?
}

struct AssistantActionFaderChange: Hashable, Sendable {
    let node: WingNodeRef
    let beforePosition: Float
    let afterPosition: Float
    let beforeMuted: Bool
    let afterMuted: Bool
    let changesMute: Bool
}

/// Immutable, in-memory review. Deliberately not Codable: restored cards cannot confirm anything.
struct AssistantActionReview: Identifiable, Hashable, Sendable {
    enum Stage: String, Hashable, Sendable { case chooseCandidate, ready }

    let id: UUID
    let submissionID: UUID
    let stage: Stage
    let targetMention: String
    let candidates: [AssistantActionCandidate]
    let selectedCandidateID: String?
    let target: AssistantActionTargetEvidence?
    let faderChanges: [AssistantActionFaderChange]
    let addsLiveShortcut: Bool
    let suggestedAmountDB: Float?
    let expiresAt: Date
    let summary: String
    let warnings: [String]
}

enum AssistantActionPreparation: Sendable {
    case answer
    case clarification(String)
    case review(AssistantActionReview)
}

struct AssistantActionResult: Identifiable, Hashable, Sendable {
    enum LocalStatus: String, Hashable, Sendable { case notRequested, added, alreadyPresent, failed, notAttempted }
    enum MemberStatus: String, Hashable, Sendable { case notSent, sentUnconfirmed, confirmed, readbackDiffers }
    struct Member: Hashable, Sendable {
        let node: WingNodeRef
        let status: MemberStatus
    }

    let id: UUID
    let reviewID: UUID
    let localStatus: LocalStatus
    let shortcutNodeID: UUID?
    let members: [Member]
    let message: String
}

/// Inject this narrow surface into chat; do not inject AppModel, WingController or a model tool.
/// Prepare/selection perform GETs and local planning only. Confirm consumes once before its first await.
@MainActor
protocol AssistantActionPlanning: AnyObject {
    var pendingReview: AssistantActionReview? { get }
    var latestResult: AssistantActionResult? { get }
    func prepare(_ request: AssistantActionInterpretationRequest,
                 interpretation: AssistantActionInterpretation) async -> AssistantActionPreparation
    func selectCandidate(reviewID: UUID, candidateID: String) async -> AssistantActionPreparation
    func confirm(reviewID: UUID) async -> AssistantActionResult
    func cancel()
}
