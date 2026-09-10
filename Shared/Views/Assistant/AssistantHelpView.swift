import SwiftUI

struct AssistantHelpView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: FluxKlangHelpEntry

    var body: some View {
        NavigationStack {
            List {
                Section(entry.title) {
                    Text(entry.overview)
                }
                if !entry.errorGuidance.isEmpty {
                    Section("When Something Is Wrong") {
                        ForEach(entry.errorGuidance, id: \.self) { guidance in
                            Label(guidance, systemImage: "exclamationmark.triangle")
                        }
                    }
                }
            }
            .navigationTitle("FluxKlang Help")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
