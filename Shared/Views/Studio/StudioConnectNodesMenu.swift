import SwiftUI

struct StudioConnectNodesMenu: View {
    let graph: StudioGraph
    let title: (StudioNode) -> String
    let connect: (StudioNode.ID, StudioNode.ID) -> Void

    var body: some View {
        Menu {
            ForEach(sourceNodes) { source in
                Menu(title(source)) {
                    ForEach(graph.nodes.filter { $0.id != source.id }) { destination in
                        Button(title(destination)) {
                            connect(source.id, destination.id)
                        }
                    }
                }
            }
        } label: {
            Label("Connect Nodes", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        }
        .disabled(sourceNodes.isEmpty)
        .accessibilityIdentifier("studio.connectNodes")
        .accessibilityHint("Provides a non-drag way to connect Studio nodes")
    }

    private var sourceNodes: [StudioNode] {
        graph.nodes.filter {
            if case .endpoint = $0.kind { return false }
            return true
        }
    }
}
