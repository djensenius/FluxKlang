enum AppSection: String, CaseIterable, Identifiable {
    case studio = "Studio"
    case workspace = "Workspace"
    case assistant = "Assistant"
    case mix = "Mix"
    case patchbay = "Routing"
    case connection = "Connection"
    case tutorial = "Learn"
    case advanced = "Compatibility"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .studio: return "square.stack.3d.up"
        case .workspace: return "point.3.connected.trianglepath.dotted"
        case .assistant: return "sparkles"
        case .mix: return "slider.vertical.3"
        case .patchbay: return "point.topleft.down.to.point.bottomright.curvepath"
        case .connection: return "antenna.radiowaves.left.and.right"
        case .tutorial: return "graduationcap"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}
