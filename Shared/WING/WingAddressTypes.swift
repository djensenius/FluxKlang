/// The strip types FluxKlang addresses on the WING.
enum WingNodeKind: String, CaseIterable, Sendable, Codable {
    case channel = "ch"
    case aux
    case bus
    case main
    case matrix = "mtx"
    case dca

    /// Number of strips of this kind on a WING Rack.
    var count: Int {
        switch self {
        case .channel: return 40
        case .aux: return 8
        case .bus: return 16
        case .main: return 4
        case .matrix: return 8
        case .dca: return 16
        }
    }

    /// Human-readable singular label for a strip of this kind.
    var label: String {
        switch self {
        case .channel: return "Channel"
        case .aux: return "Aux"
        case .bus: return "Bus"
        case .main: return "Main"
        case .matrix: return "Matrix"
        case .dca: return "DCA"
        }
    }
}

enum WingOutputConnectorBank: String, CaseIterable, Codable, Hashable, Sendable {
    case local = "LCL"
    case aes50A = "A"
    case aes50B = "B"
    case aes50C = "C"

    var label: String {
        switch self {
        case .local: "Local"
        case .aes50A: "AES50-A"
        case .aes50B: "AES50-B"
        case .aes50C: "AES50-C"
        }
    }

    var connectorRange: ClosedRange<Int> {
        switch self {
        case .local: 1...8
        case .aes50A, .aes50B, .aes50C: 1...16
        }
    }
}
