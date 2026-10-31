//
//  PermissionProbe.swift
//  FluxKlang
//
//  System side of the permission model. Reading a status never prompts;
//  `request` must only run from an explicit user action. Test hosts get
//  `InertPermissionProbe` through `HardwareServiceFactories`.
//

import AVFAudio
import Foundation

@MainActor
protocol PermissionProbe: AnyObject {
    /// Never shows a system prompt.
    func status(of capability: PermissionCapability) -> PermissionStatus
    /// May show a system prompt. Call only from an explicit user action.
    func request(_ capability: PermissionCapability) async -> PermissionStatus
}

extension PermissionProbe {
    func state(of capability: PermissionCapability) -> PermissionState {
        PermissionState(capability: capability, status: status(of: capability))
    }
}

@MainActor
final class SystemPermissionProbe: PermissionProbe {
    private let localNetworkEvidence: LocalNetworkGrantEvidence

    init(localNetworkEvidence: LocalNetworkGrantEvidence = .current) {
        self.localNetworkEvidence = localNetworkEvidence
    }

    func status(of capability: PermissionCapability) -> PermissionStatus {
        switch capability {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .localNetwork:
            // Evidence only (a past successful connect, possibly to a routed host); never queried
            // from the OS, which has no API for it. Not used by production code paths today.
            return localNetworkEvidence.hasGrant ? .granted : .unknown
        case .multicast:
            return LocalNetworkAccess.currentBroadcastDiscovery.status
        case .bluetooth:
            return .unsupported
        }
    }

    func request(_ capability: PermissionCapability) async -> PermissionStatus {
        // Local Network has no request API (TN3179): the user-initiated connect is the request.
        guard capability == .microphone else { return status(of: capability) }
        return await AVAudioApplication.requestRecordPermission() ? .granted : .denied
    }
}

/// Never touches AVFAudio or the network; records requests so tests can prove none happen.
@MainActor
final class InertPermissionProbe: PermissionProbe {
    private(set) var requests: [PermissionCapability] = []

    func status(of capability: PermissionCapability) -> PermissionStatus { .unknown }

    func request(_ capability: PermissionCapability) async -> PermissionStatus {
        requests.append(capability)
        return .unknown
    }
}

/// On-device record that this app reached `host` after a user action. TN3179
/// ties the privilege to the install and code signature, not the build number,
/// so the record is keyed on bundle ID + host only. It lives in a directory
/// excluded from backups (set before the first write), so a restore onto a new
/// device, where the privilege starts undetermined, never inherits it. A stale
/// record is cleared after one possibly-denied connect to that host.
struct LocalNetworkGrantEvidence: Sendable {
    let directory: URL
    let bundleID: String

    var fileURL: URL { directory.appendingPathComponent("local-network-grant", isDirectory: false) }

    static let current = LocalNetworkGrantEvidence(
        directory: AppPersistence.directory.appendingPathComponent("LocalNetwork", isDirectory: true),
        bundleID: Bundle.main.bundleIdentifier ?? "?"
    )

    /// Whether this app reached the local network on this device at all.
    var hasGrant: Bool { record?.bundleID == bundleID }

    func hasGrant(for host: String) -> Bool {
        record.map { $0.bundleID == bundleID && $0.host == host } ?? false
    }

    func recordGrant(for host: String) {
        guard !hasGrant(for: host) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = directory
            try excluded.setResourceValues(values)
            try "\(bundleID)\n\(host)".write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            clear()
        }
    }

    /// Clears the record only when it names `host`.
    func clear(host: String) {
        if record?.host == host { clear() }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private var record: (bundleID: String, host: String)? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2 else { return nil }
        return (String(lines[0]), String(lines[1]))
    }
}
