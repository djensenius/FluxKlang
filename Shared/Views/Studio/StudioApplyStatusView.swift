import SwiftUI

struct StudioApplyStatusView: View {
    var graphIsEmpty: Bool
    var hasIssues: Bool
    var isConnected: Bool
    var isApplying: Bool
    var settings: [WingSetting]
    var verification: WingApplyVerification?
    var endpointCount: Int
    var connectionCount: Int
    var apply: () -> Void

    private var currentVerification: WingApplyVerification? {
        guard isConnected, !settings.isEmpty, verification?.settings == settings else { return nil }
        return verification
    }

    var body: some View {
        StudioStatusCard(
            title: title,
            detail: detail,
            systemImage: systemImage,
            tint: tint
        )
        .accessibilityIdentifier("studio.status")
        if !graphIsEmpty, !hasIssues {
            Button(action: apply) {
                if isApplying {
                    ProgressView()
                } else {
                    Label(
                        currentVerification != nil ? "Send Again" : "Listen on WING",
                        systemImage: "bolt.horizontal.circle"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isConnected || settings.isEmpty || isApplying)
            .accessibilityIdentifier("studio.listenPrimary")
        }
    }

    private var title: String {
        if graphIsEmpty { return "Ready to make a patch" }
        if hasIssues { return "Some parts need attention" }
        if isApplying { return "Checking WING routing" }
        switch currentVerification?.state {
        case .verified: return "Verified on WING"
        case .partiallyVerified: return "Partially verified"
        case .failed: return "Could not verify routing"
        case nil: return "Ready to send to WING"
        }
    }

    private var detail: String {
        if graphIsEmpty {
            return "Pick a sound, give it a dry control, give it a space control, then explore."
        }
        if hasIssues {
            return "Resolve the notes below before sending this patch."
        }
        if isApplying {
            return "Safe endpoint levels are confirmed before the remaining routing is sent."
        }
        if let currentVerification {
            if currentVerification.state == .verified {
                return """
                Routing is confirmed and remains muted at a safe level. Raise its control, then unmute when ready.
                """
            }
            return currentVerification.details
        }
        if !isConnected {
            return "Connect to the WING, then choose Listen on WING."
        }
        return "\(endpointCount) controls · \(connectionCount) connections · not sent yet"
    }

    private var systemImage: String {
        if hasIssues { return "exclamationmark.triangle.fill" }
        switch currentVerification?.state {
        case .verified: return "checkmark.circle.fill"
        case .partiallyVerified: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case nil: return isApplying ? "arrow.triangle.2.circlepath" : "arrow.up.circle.fill"
        }
    }

    private var tint: Color {
        if hasIssues { return .orange }
        switch currentVerification?.state {
        case .verified: return .green
        case .partiallyVerified: return .orange
        case .failed: return .red
        case nil: return .blue
        }
    }
}
