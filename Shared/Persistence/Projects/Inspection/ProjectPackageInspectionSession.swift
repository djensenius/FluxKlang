import Foundation

enum ProjectPackageInspectionSessionRefusal: Error, Equatable, Sendable, CaseIterable {
    case busy
    case windowCapacity
    case retainedCapacity
    case invalidRegistration
}

/// A join handle, not another owner of an inspection. Completed handles retain only a small outcome.
@MainActor
final class ProjectPackageInspectionRequest {
    enum Outcome: Equatable, Sendable {
        case published
        case refused(ProjectPackageInspectionRefusal)
        case cancelled
    }

    fileprivate var task: Task<Void, Never>?
    fileprivate(set) var outcome: Outcome?

    fileprivate init() {}

    func join() async {
        await task?.value
    }

    fileprivate func complete(_ outcome: Outcome) {
        self.outcome = outcome
        task = nil
    }
}

/// One app-owned instance must be shared across windows. Serialization is local to this owner.
/// A blocked synchronous read can hold the slot indefinitely, including after cancellation.
/// This provides no prompt interruption, memory bound, snapshot or provider guarantee.
@MainActor
final class ProjectPackageInspectionSession {
    /// Return only after all owned work and access-lifetime cleanup have finished.
    typealias Operation = @Sendable (URL) async throws(ProjectPackageInspectionRefusal) -> ProjectPackageInspection

    struct Registration: Hashable, Sendable {
        let window: WindowID
        fileprivate let owner: UUID
        fileprivate let lifetime: UUID
    }

    enum Phase: Equatable, Sendable {
        case acquiring
        case draining
    }

    struct Acquisition {
        let registration: Registration
        let request: ProjectPackageInspectionRequest
        fileprivate(set) var phase: Phase
    }

    static let windowLimit = 16
    static let retainedLimit = 2

    private let owner = UUID()
    private let operation: Operation
    private var windows: [WindowID: Registration] = [:]
    private var inspections: [WindowID: ProjectPackageInspection] = [:]
    private(set) var acquisition: Acquisition?

    var windowCount: Int { windows.count }
    var retainedCount: Int { inspections.count }

    init(operation: @escaping Operation = { url throws(ProjectPackageInspectionRefusal) in
        try await ProjectPackageInspectionLoader().load(at: url)
    }) {
        self.operation = operation
    }

    /// Opening an already-live window is idempotent; reopening a closed window gets a new lifetime.
    func openWindow(_ window: WindowID) throws(ProjectPackageInspectionSessionRefusal) -> Registration {
        if let registration = windows[window] { return registration }
        guard windows.count < Self.windowLimit else { throw .windowCapacity }
        let registration = Registration(window: window, owner: owner, lifetime: UUID())
        windows[window] = registration
        return registration
    }

    func inspection(in registration: Registration) throws(ProjectPackageInspectionSessionRefusal)
        -> ProjectPackageInspection? {
        try validate(registration)
        return inspections[registration.window]
    }

    /// Validation and reservation are synchronous. Refusals never enqueue or retry work.
    func beginInspection(
        at root: URL, in registration: Registration
    ) throws(ProjectPackageInspectionSessionRefusal) -> ProjectPackageInspectionRequest {
        try validate(registration)
        guard acquisition == nil else { throw .busy }
        guard inspections[registration.window] != nil || inspections.count < Self.retainedLimit else {
            throw .retainedCapacity
        }
        let request = ProjectPackageInspectionRequest()
        acquisition = Acquisition(registration: registration, request: request, phase: .acquiring)
        let operation = operation
        request.task = Task {
            let result: Result<ProjectPackageInspection, ProjectPackageInspectionRefusal>
            do throws(ProjectPackageInspectionRefusal) {
                result = .success(try await operation(root))
            } catch {
                result = .failure(error)
            }
            // The operation, including its access-lifetime cleanup, has returned before this point.
            finalize(result, request: request, registration: registration)
        }
        return request
    }

    @discardableResult
    func cancel(_ request: ProjectPackageInspectionRequest) -> Bool {
        guard let current = acquisition, current.request === request,
              windows[current.registration.window] == current.registration else { return false }
        acquisition?.phase = .draining
        request.task?.cancel()
        return true
    }

    func closeInspection(in registration: Registration) throws(ProjectPackageInspectionSessionRefusal) {
        try validate(registration)
        if let acquisition, acquisition.registration == registration {
            cancel(acquisition.request)
        }
        inspections[registration.window] = nil
    }

    func closeWindow(_ registration: Registration) throws(ProjectPackageInspectionSessionRefusal) {
        try closeInspection(in: registration)
        windows[registration.window] = nil
    }

    private func validate(_ registration: Registration) throws(ProjectPackageInspectionSessionRefusal) {
        guard registration.owner == owner, windows[registration.window] == registration else {
            throw .invalidRegistration
        }
    }

    private func finalize(
        _ result: Result<ProjectPackageInspection, ProjectPackageInspectionRefusal>,
        request: ProjectPackageInspectionRequest, registration: Registration
    ) {
        guard let current = acquisition, current.request === request else {
            request.complete(.cancelled)
            return
        }
        if current.phase == .acquiring, current.registration == registration,
           windows[registration.window] == registration {
            switch result {
            case .success(let inspection):
                inspections[registration.window] = inspection
                request.complete(.published)
            case .failure(let refusal):
                request.complete(refusal == .cancelled ? .cancelled : .refused(refusal))
            }
        } else {
            request.complete(.cancelled)
        }
        acquisition = nil
    }
}
