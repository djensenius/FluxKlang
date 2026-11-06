//
//  NeutralDiagnosticRecord.swift
//  FluxKlang
//
//  A host-neutral diagnostic fact offered to `NeutralSnapshot`. It names its
//  subject only by contract IDs; its summary is untrusted display text.
//
//  PROVISIONAL: these types are local to the snapshot until diagnostic
//  producers exist. They will then be promoted to `Shared/Contracts/Diagnostics`
//  with typed errors and re-validating Codable.
//

import Foundation

enum DiagnosticTag: ContractIDTag {}
typealias DiagnosticID = ContractID<DiagnosticTag>

/// How urgent a diagnostic is. `error` sorts before `warning` before `info`.
enum DiagnosticSeverity: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case error
    case warning
    case info

    /// 0 for the most urgent severity.
    var rank: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .info: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// What a diagnostic is about, by neutral ID only.
enum DiagnosticSubject: Hashable, Sendable, Encodable {
    case graph
    case node(id: NodeID)
    case port(node: NodeID, port: PortID)
    case edge(id: EdgeID)
    case parameter(id: ParameterID)
    case route(id: RouteID)
}

/// One diagnostic as produced by a status or validation owner.
struct NeutralDiagnosticRecord: Hashable, Sendable {
    var id: DiagnosticID
    var severity: DiagnosticSeverity
    var summary: String
    var subject: DiagnosticSubject?

    init(id: DiagnosticID, severity: DiagnosticSeverity, summary: String, subject: DiagnosticSubject? = nil) {
        self.id = id
        self.severity = severity
        self.summary = summary
        self.subject = subject
    }
}
