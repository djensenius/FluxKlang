import SwiftUI

struct StudioHostPermissionView: View {
    var owner: HostUserPermissionOwner = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Host permission", systemImage: "person.badge.key")
                .font(.headline)
            Text("""
            Apply on a real WING needs the Host role, granted each launch. Demo Mode and mixer controls do not use it.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Revoking does not stop hardware or cancel writes already underway.")
                .font(.caption)
                .foregroundStyle(.secondary)
            outcome
                .accessibilityIdentifier("studio.permission.outcome")
            observation
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("studio.permission.lastChecked")
            if owner.isBusy {
                ProgressView("Updating Host permission")
                    .accessibilityIdentifier("studio.permission.busy")
            }
            HStack {
                Button("Grant Host role") { owner.submit(.grant) }
                    .accessibilityIdentifier("studio.permission.grant")
                Button("Revoke Host role") { owner.submit(.revoke) }
                    .accessibilityIdentifier("studio.permission.revoke")
            }
            .buttonStyle(.bordered)
            .disabled(owner.isBusy)
        }
        .accessibilityIdentifier("studio.permission")
    }

    @ViewBuilder
    private var outcome: some View {
        switch owner.report?.outcome {
        case nil: Text("No permission action yet.")
        case .granted: Text("Last action: Host grant completed.")
        case .revoked: Text("Last action: Host revoke completed.")
        case .revisionExhausted: Text("Last action: grant refused; permission revisions exhausted.")
        }
    }

    @ViewBuilder
    private var observation: some View {
        switch owner.report?.lastChecked {
        case nil: Text("Permission not checked.")
        case .present: Text("Last checked: permission was present. This is not current authorization.")
        case .absent: Text("Last checked: permission was absent. This is not current authorization.")
        }
    }
}
