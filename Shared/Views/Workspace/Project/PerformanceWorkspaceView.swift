import SwiftUI

/// A neutral document editor. Ownership and root/window lifetime stay with the coordinator.
struct PerformanceWorkspaceView: View {
    let session: PerformanceProjectSession?
    let window: WindowID
    let newProject: () -> Void
    @Environment(PerformancePackageInspectionWindow.self) private var packageInspection:
        PerformancePackageInspectionWindow?
    @State private var editFailure: String?

    init(session: PerformanceProjectSession?, window: WindowID, newProject: @escaping () -> Void) {
        self.session = session
        self.window = window
        self.newProject = newProject
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Workspace").font(.largeTitle)
                switch content {
                case .inspection(let returnTitle):
                    if let packageInspection {
                        inspectionPanel(packageInspection, returnTitle: returnTitle)
                    }
                case .editor:
                    header
                    if let session { editor(session) }
                case .retained:
                    header
                    Text("Your unsaved project is retained.")
                    Button("Open Project", action: newProject)
                case .empty:
                    header
                    Text("Create an unsaved project with two confirmed stereo software roles and one draft connection.")
                    Text("Roles are portable intentions, not discovered devices or physical cable confirmations.")
                        .foregroundStyle(.secondary)
                    Button("New Project", action: newProject)
                }
                if let editFailure {
                    Text("Edit not applied: \(editFailure)")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Edit not applied. \(editFailure)")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var content: PerformanceWorkspaceContent {
        PerformanceWorkspaceContent.resolve(
            starter: session, window: window, isInspecting: packageInspection?.isInspecting ?? false
        )
    }

    @ViewBuilder
    private var header: some View {
        Text(session == nil ? "No project yet" : "Unsaved • Draft • Not active").font(.headline)
        Text("Software-routing draft only. Native activation unavailable. Nothing here changes live routing.")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func inspectionPanel(_ model: PerformancePackageInspectionWindow, returnTitle: String) -> some View {
        Text("Read-only • Not active").font(.headline)
        Text("Inspecting a package never changes it, your unsaved project or live routing.")
            .foregroundStyle(.secondary)
        if let inspection = model.inspection {
            let project = inspection.documents.project
            let reviewCount = inspection.diagnostics.reviewRequiredGraphs.count
            Text(project.name).font(.title2)
            Text("Project revision \(project.revision.value)")
            Text("Pinned graphs: \(project.graphs.count) • Review required: \(reviewCount)")
        }
        if let line = Self.statusLine(model.status) {
            Text(line).foregroundStyle(.secondary)
        }
        if model.isOpening {
            Button("Cancel Opening") { model.cancelOpening() }
                .disabled(model.status == .cancelling)
        }
        Button(returnTitle) { model.returnToUnsavedProject() }
    }

    private static func statusLine(_ status: PerformancePackageInspectionWindow.Status) -> String? {
        switch status {
        case .idle: nil
        case .opening: "Opening package…"
        case .cancelling: "Cancelling…"
        case .cancelled: "Opening cancelled. Nothing changed."
        case .refused(let refusal): "Package not opened (\(refusal)). Nothing changed."
        case .unavailable(.busy): "Another package is opening. Try again when it finishes."
        case .unavailable(.retainedCapacity): "Two packages are already open for inspection. Close one first."
        case .unavailable: "Package inspection is unavailable in this window."
        }
    }

    @ViewBuilder
    private func editor(_ session: PerformanceProjectSession) -> some View {
        Text(session.project.name).font(.title2)
        Text("Unsaved in memory — closing the app discards this project.")
            .foregroundStyle(.secondary)
        ForEach(session.project.roles) { role in
            Text("\(role.label): \(role.direction.rawValue) role, \(role.channels ?? 0) audio channels")
        }
        Toggle("Stereo connection in draft", isOn: Binding(
            get: { session.stereoConnectionEnabled },
            set: { enabled in edit { try session.setStereoConnectionEnabled(enabled) } }
        ))
        Text("Source → Output starter connection. Endpoints and connection metadata are fixed."
             + " Removing this connection only edits the draft.")
            .foregroundStyle(.secondary)
        HStack {
            Button("Undo") { edit { try session.undo() } }
                .disabled(session.snapshot.history.undoCount == 0)
            Button("Redo") { edit { try session.redo() } }
                .disabled(session.snapshot.history.redoCount == 0)
        }
        Text("Undo: \(session.snapshot.history.undoCount) • Redo: \(session.snapshot.history.redoCount)")
            .font(.caption)
        PerformanceWiringListView(session: session, edit: edit)
        PerformanceDraftReviewView(diff: session.snapshot.diff, baseRevision: session.base.revision)
        // No plug-in scanner is connected yet, so the catalog is the honest never-scanned one.
        LibrarySectionView(patches: session.project.patches, catalog: PluginCatalog())
    }

    @discardableResult
    private func edit(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            editFailure = nil
            return true
        } catch {
            editFailure = PerformanceWiringText.failure(error)
            return false
        }
    }
}
