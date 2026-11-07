/// A non-interleaved (planar) floating-point sample format. Interleaved and integer formats are unsupported.
enum RenderSampleFormat: String, CaseIterable, Sendable, Hashable {
    case float32
    case float64

    var bytesPerSample: Int {
        switch self {
        case .float32: 4
        case .float64: 8
        }
    }
}
