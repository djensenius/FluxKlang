import Foundation

extension AppModel {
    func configureAssistantActions() {
        assistantChat.actionPlanner = assistantActions
        assistantChat.currentRoutingContext = { [weak self] in self?.assistantToolContext() }
    }

    func makeAssistantActionController() -> AssistantActionController {
        AssistantActionController(controller: { [weak self] in self?.wing }, layout: { [weak self] in
            self?.faderLayout.layout ?? FaderLayout()
        }, scope: { [weak self] in
            guard let self else {
                return AssistantActionScope(environmentID: nil, graph: StudioGraph(), endpoints: [],
                                            equipment: [], connections: StudioHomeConnections())
            }
            return AssistantActionScope(environmentID: self.environments.active?.id,
                graph: self.environments.activeStudioGraph, endpoints: self.environments.activeStudioEndpoints,
                equipment: self.equipment.items, connections: self.studioConnectionsForCurrentWing().effectiveHome)
        }, addShortcut: { [weak self] binding, title, environmentID, graph in
            self?.environments.addLiveChannelShortcut(binding, title: title,
                                                      environmentID: environmentID, expectedGraph: graph)
        })
    }
}
