import SwiftUI

/// A neutral document editor. Ownership and root/window lifetime stay with the coordinator.
struct PerformanceWorkspaceView: View {
    let session: PerformanceProjectSession?
    let window: WindowID
    let newProject: () -> Void
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
                Text(session == nil ? "No project yet" : "Unsaved • Draft • Not active").font(.headline)
                Text("Software-routing draft only. Native activation unavailable. Nothing here changes live routing.")
                    .foregroundStyle(.secondary)
                if let session {
                    if session.navigation.windowProjects[window] == session.project.id {
                        editor(session)
                    } else {
                        Text("Your unsaved project is retained.")
                        Button("Open Project", action: newProject)
                    }
                } else {
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
