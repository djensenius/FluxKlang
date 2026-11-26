//
//  EnvironmentPersistenceWarning.swift
//  FluxKlang
//
//  Root-level stopped/unsaved environment state (#943). Reload or a user-confirmed start-fresh (#947, local data
//  only) are the only ways to clear a hold; start-fresh moves the named item into `Preserved`, never deletes it.
//

import SwiftUI

struct EnvironmentPersistenceWarning: View {
    let model: AppModel
    @State private var confirming: EnvironmentLoadHold?

    private var environments: EnvironmentStore { model.environments }
    /// A start-fresh or a read is running: neither action can act until it finishes.
    private var isBusy: Bool { model.environmentPreservation?.isInProgress == true || environments.isReading }

    var body: some View {
        if environments.hold != nil || environments.lastSaveFailed || model.environmentPreservation != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let hold = environments.hold {
                    held(hold)
                } else if environments.lastSaveFailed {
                    Label("Recent environment changes weren't saved.", systemImage: "exclamationmark.triangle.fill")
                }
                if let status = model.environmentPreservation {
                    HStack {
                        Label(status.message, systemImage: "archivebox")
                        Spacer()
                        if !status.isInProgress {
                            Button("Dismiss") { model.dismissEnvironmentPreservation() }
                        }
                    }
                }
            }
            .warningBanner()
            .confirmationDialog(
                "Move \(confirming?.fileName ?? "the file") and start fresh?",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { hold in
                Button("Move \(hold.fileName) and Start Fresh") {
                    Task { await model.preserveHeldEnvironmentsAndStartFresh(confirmed: hold) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { hold in
                Text("\(hold.fileName) will be moved, unchanged, into the \(JSONFileStore.preservedDirectoryName) "
                    + "folder in FluxKlang's app data. It isn't deleted. Saved environments are then read again "
                    + "without it, and environment and Home data may be saved as soon as they reload, including "
                    + "to iCloud, where it can reach your other devices.")
            }
        }
    }

    private func held(_ hold: EnvironmentLoadHold) -> some View {
        HStack {
            Label(hold.message, systemImage: "exclamationmark.octagon.fill")
            Spacer()
            Button("Reload") { Task { await model.reloadHeldEnvironments() } }
                .disabled(isBusy)
                .accessibilityHint("Reads saved environments again")
            if hold.isLocal {
                Button("Start Fresh…") { confirming = hold }
                    .disabled(isBusy)
                    .accessibilityHint("Asks before moving \(hold.fileName) aside and reading saved environments again")
            }
        }
    }
}

private extension View {
    func warningBanner() -> some View {
        font(.callout)
            .foregroundStyle(.orange)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
    }
}
