//
//  OpenSoundControl+Namespace.swift
//  FluxKlang
//
//  The closed vocabularies and bounds of the neutral OSC namespace `/fk/v1`
//  (#89, slice O2a). Provisional v1 (Q-OSC-NS): no inbound wildcards. The
//  address table for controllers is generated from `RouteTable`, not copied.
//

extension OpenSoundControl {
    /// Every bound of the namespace grammar, as literals in one place. Provisional v1; Q-OSC-NS.
    /// Each bound is checked as `count > limit`: N is accepted and N + 1 is refused. The ramp
    /// literal repeats `CommandIntentFields.validate`, which stays the authority at admission.
    enum NamespaceLimits {
        static let maximumAddressBytes = 256
        static let maximumSegments = 6
        static let maximumSegmentBytes = 32
        static let maximumRoutes = 128
        static let maximumBatchMessages = 1_024
        static let maximumRampMilliseconds = 60_000
        /// The namespace prefix `/fk/v1` as segment bytes.
        static let namespaceSegments: [[UInt8]] = [Array("fk".utf8), Array("v1".utf8)]

        /// Whether `byte` belongs to `[a-z0-9_-]`, the only bytes of a name segment.
        static func isNameByte(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// The families that map to live operations. Raw values are the segment bytes after `/fk/v1/`.
    enum NamespaceFamily: String, CaseIterable, Sendable, Hashable {
        case param, action, transport
    }

    /// Families that are recognised and refused by name; no table can route them.
    enum RefusedFamily: String, CaseIterable, Sendable, Hashable {
        case route, patch, draft, safety, hazard

        /// The control class the refused family stands for (documentation and test oracle only).
        var controlClass: ControlClass {
            switch self {
            case .route, .patch: .structural
            case .draft: .proposal
            case .safety: .safety
            case .hazard: .hazardous
            }
        }
    }

    /// The transport verbs that can be enabled in a `RouteTable`.
    enum TransportVerb: String, CaseIterable, Sendable, Hashable {
        case start, stop, locate
    }
}
