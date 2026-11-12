import SwiftUI

/// One patch row with its variations nested and indented under it. Only disabled actions are drawn (see
/// `LibraryDisabledActionView`).
struct LibraryPatchRowView: View {
    let row: LibraryPatchRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                LibraryAdaptiveLine {
                    Text(row.title)
                    Text(row.kindText).font(.caption).foregroundStyle(.secondary)
                }
                Text(row.detailText).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.accessibilityLabel)
            disabledActions(row.actions)
            ForEach(row.variations) { variation in
                variationRow(variation)
                    .padding(.leading, 20)
            }
        }
    }

    private func variationRow(_ variation: LibraryVariationRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                LibraryAdaptiveLine {
                    Text(variation.title)
                    Text(variation.kindText).font(.caption).foregroundStyle(.secondary)
                }
                Text(variation.detailText).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(variation.accessibilityLabel)
            disabledActions(variation.actions)
        }
    }

    @ViewBuilder
    private func disabledActions(_ actions: [LibraryPatchAction]) -> some View {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            if let reason = action.disabledReason {
                LibraryDisabledActionView(title: action.title, reason: reason)
            }
        }
    }
}
