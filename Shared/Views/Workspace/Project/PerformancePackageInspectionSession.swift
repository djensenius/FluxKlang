import Foundation
import Observation

/// One root window's view of the app-owned inspection owner, which stays the single source of
/// truth: this mirrors it after every action and completion. It never holds or creates the starter.
@MainActor
@Observable
final class PerformancePackageInspectionWindow {
    enum Status: Equatable, Sendable {
        case idle
        case opening
        case cancelling
        case refused(ProjectPackageInspectionRefusal)
        case cancelled
        case unavailable(ProjectPackageInspectionSessionRefusal)
    }

    private(set) var inspection: ProjectPackageInspection?
    private(set) var status: Status
    private var request: ProjectPackageInspectionRequest?
    @ObservationIgnored private let owner: ProjectPackageInspectionSession
    @ObservationIgnored private var registration: ProjectPackageInspectionSession.Registration?
    @ObservationIgnored private var completions: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// A refused registration leaves this model inert.
    init(owner: ProjectPackageInspectionSession, window: WindowID) {
        self.owner = owner
        do throws(ProjectPackageInspectionSessionRefusal) {
            registration = try owner.openWindow(window)
            status = .idle
        } catch {
            registration = nil
            status = .unavailable(error)
        }
    }

    var isOpening: Bool { request != nil }

    var isInspecting: Bool {
        registration != nil && (inspection != nil || request != nil || status != .idle)
    }

    /// A refusal keeps the existing inspection and pending request; nothing is queued or retried.
    func open(at url: URL) {
        guard let registration else { return }
        do throws(ProjectPackageInspectionSessionRefusal) {
            let request = try owner.beginInspection(at: url, in: registration)
            self.request = request
            status = .opening
            completions[ObjectIdentifier(request)] = Task { [weak self] in
                await request.join()
                self?.complete(request)
            }
        } catch {
            status = .unavailable(error)
        }
        refresh()
    }

    func cancelOpening() {
        guard let request, owner.cancel(request) else { return }
        status = .cancelling
    }

    /// Releases this window's retained inspection; a pending read keeps the slot until it ends.
    func returnToUnsavedProject() {
        guard let registration else { return }
        do throws(ProjectPackageInspectionSessionRefusal) {
            try owner.closeInspection(in: registration)
            status = .idle
        } catch {
            refuse(error)
        }
        request = nil
        refresh()
    }

    /// Idempotent. Later completions are ignored.
    func close() {
        guard let registration else { return }
        try? owner.closeWindow(registration)
        self.registration = nil
        request = nil
        inspection = nil
        status = .idle
    }

    /// Waits for every completion this model started. Test hook.
    func join() async {
        for task in Array(completions.values) { await task.value }
    }

    private func complete(_ finished: ProjectPackageInspectionRequest) {
        completions[ObjectIdentifier(finished)] = nil
        guard registration != nil, request === finished else { return }
        request = nil
        switch finished.outcome {
        case .published, nil: status = .idle
        case .refused(let refusal): status = .refused(refusal)
        case .cancelled: status = .cancelled
        }
        refresh()
    }

    private func refresh() {
        guard let registration else { return }
        do throws(ProjectPackageInspectionSessionRefusal) {
            inspection = try owner.inspection(in: registration)
        } catch {
            refuse(error)
        }
    }

    /// A registration the owner no longer recognises leaves this model inert, as if closed.
    private func refuse(_ refusal: ProjectPackageInspectionSessionRefusal) {
        status = .unavailable(refusal)
        guard refusal == .invalidRegistration else { return }
        registration = nil
        request = nil
        inspection = nil
    }
}

/// What the Workspace shows for one window. An inspection wins; nothing here creates a starter.
enum PerformanceWorkspaceContent: Equatable, Sendable {
    static let returnToStarterTitle = "Return to Unsaved Project"
    static let closeInspectionTitle = "Close Inspection"

    case inspection(returnTitle: String)
    case editor
    case retained
    case empty

    @MainActor
    static func resolve(starter: PerformanceProjectSession?, window: WindowID, isInspecting: Bool) -> Self {
        if isInspecting {
            return .inspection(returnTitle: starter == nil ? closeInspectionTitle : returnToStarterTitle)
        }
        guard let starter else { return .empty }
        return starter.navigation.windowProjects[window] == starter.project.id ? .editor : .retained
    }
}
