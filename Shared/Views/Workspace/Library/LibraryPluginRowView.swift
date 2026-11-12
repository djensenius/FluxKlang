import SwiftUI

/// One disabled action with its reason as visible text. Enabled actions are not drawn: nothing handles an action
/// yet, so an enabled button would do nothing. They arrive with their handlers (the #99 shell integration).
struct LibraryDisabledActionView: View {
    let title: String
    let reason: String

    var body: some View {
        HStack(spacing: 8) {
            Button(title) {}
                .disabled(true)
                .frame(minHeight: 44)
                .accessibilityLabel("\(title). \(reason)")
            Text(reason).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

/// Lays its content out in one line when it fits and stacked otherwise (large Dynamic Type, compact widths).
struct LibraryAdaptiveLine<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { content() }
            VStack(alignment: .leading, spacing: 2) { content() }
        }
    }
}

/// One plugin row, or the never-scanned row, as the model describes it. Status is always text.
struct LibraryPluginRowView: View {
    let title: String
    let kindText: String?
    let statusText: String
    let secondaryText: String?
    let reasonText: String?
    let actions: [LibraryPluginAction]
    let accessibilityLabel: String

    init(row: LibraryPluginRow) {
        title = row.title
        kindText = row.kindText
        statusText = row.statusText
        secondaryText = row.secondaryText
        reasonText = row.reasonText
        actions = row.actions
        accessibilityLabel = row.accessibilityLabel
    }

    init(scanRow: LibraryPluginScanRow) {
        title = scanRow.title
        kindText = nil
        statusText = scanRow.statusText
        secondaryText = nil
        reasonText = nil
        actions = scanRow.actions
        accessibilityLabel = scanRow.accessibilityLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                LibraryAdaptiveLine {
                    Text(title)
                    if let kindText { Text(kindText).font(.caption).foregroundStyle(.secondary) }
                    Text(statusText).font(.caption.bold())
                }
                if let secondaryText { Text(secondaryText).font(.caption).foregroundStyle(.secondary) }
                if let reasonText { Text(reasonText).font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                if let reason = action.disabledReason {
                    LibraryDisabledActionView(title: action.title, reason: reason)
                }
            }
        }
    }
}
