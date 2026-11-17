//
//  WingDirectSendScope.swift
//  FluxKlang
//
//  The WING `DirectSendScopePolicy` (#62 AU5): a `.parameter` scope for one of the
//  five `ParameterCatalog` WING parameters admits only that parameter's address
//  class, on any valid strip. Per-strip binding waits for a NodeID to strip map
//  (#76). Every other scope admits nothing until its address table exists.
//

/// The direct-send address classes, parsed strictly from the shapes `WingAddress`
/// builds: `/<kind>/<index>/fdr`, `/mute`, `/pan`, `/col`, and
/// `/<kind>/<index>/send/<bus>/lvl`. `kind` is a `WingNodeKind` raw value, `index`
/// is in `1...kind.count` and `bus` in `1...WingNodeKind.bus.count`, both
/// canonical ASCII decimal. Case-sensitive, with no extra segments.
enum WingAddressClass: Hashable, Sendable {
    case fader, mute, pan, colour, sendLevel

    init?(address: String) {
        let segments = address.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 4, segments[0].isEmpty,
              let kind = WingNodeKind(rawValue: String(segments[1])),
              Self.index(segments[2], in: 1...kind.count) != nil else { return nil }
        switch Array(segments[3...]) {
        case ["fdr"]: self = .fader
        case ["mute"]: self = .mute
        case ["pan"]: self = .pan
        case ["col"]: self = .colour
        case let tail where tail.count == 3 && tail[0] == "send" && tail[2] == "lvl"
            && Self.index(tail[1], in: 1...WingNodeKind.bus.count) != nil:
            self = .sendLevel
        default: return nil
        }
    }

    /// `segment` as an index in `range`: ASCII digits only, no sign, no leading zero.
    private static func index(_ segment: Substring, in range: ClosedRange<Int>) -> Int? {
        let digits = segment.utf8
        guard let first = digits.first, first != UInt8(ascii: "0"),
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let value = Int(segment), range.contains(value) else { return nil }
        return value
    }
}

struct WingDirectSendScope: DirectSendScopePolicy {
    /// The WING parameters and the one address class each may write.
    static let parameterClasses: [ParameterID: WingAddressClass] = [
        ParameterCatalog.wingFaderDecibels: .fader,
        ParameterCatalog.wingMute: .mute,
        ParameterCatalog.wingPan: .pan,
        ParameterCatalog.wingColour: .colour,
        ParameterCatalog.wingSendDecibels: .sendLevel
    ]

    func admits(_ target: DirectSendTarget, under scope: CommandScope) -> Bool {
        switch scope {
        case .parameter(let parameter):
            guard let admitted = Self.parameterClasses[parameter] else { return false }
            return WingAddressClass(address: target.key) == admitted
        case .route, .patch, .action, .draft, .transport, .safety:
            return false
        }
    }
}
