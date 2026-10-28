import Foundation

extension StudioNode {
    var isLiveChannelShortcut: Bool {
        if case .liveChannel = kind { return true }
        return false
    }

    var isStudioControl: Bool {
        switch kind {
        case .endpoint, .liveChannel: return true
        case .instrument, .effect: return false
        }
    }

    func studioDisplayTitle(equipment: [Equipment], effects: [Effect], endpoints: [StudioEndpoint]) -> String {
        switch kind {
        case .instrument(let id): return equipment.first { $0.id == id }?.name ?? title
        case .effect(let id): return effects.first { $0.id == id }?.name ?? title
        case .endpoint(let id): return endpoints.first { $0.id == id }?.name ?? title
        case .liveChannel(let binding):
            let labels = binding.members.map { "Ch \($0.channel) · “\($0.label)”" }
            return labels.isEmpty ? "Unverified channel shortcut" : labels.joined(separator: " / ")
        }
    }
}
