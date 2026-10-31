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

/// On-device record that this build reached `host` after a user action. The
/// file is excluded from backups so a restore onto a new device, where the
/// privilege starts undetermined, never inherits it. A new app version also
/// starts without evidence, so its first WING connect is a user action.
struct LocalNetworkGrantEvidence: Sendable {
    let fileURL: URL
    let buildFingerprint: String

    static let current = LocalNetworkGrantEvidence(
        fileURL: AppPersistence.directory.appendingPathComponent("local-network-grant", isDirectory: false),
        buildFingerprint: mainBundleFingerprint
    )

    static var mainBundleFingerprint: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)-\(build)"
    }

    /// Whether this build reached the local network on this device at all.
    var hasGrant: Bool { record?.fingerprint == buildFingerprint }

    func hasGrant(for host: String) -> Bool {
        record.map { $0.fingerprint == buildFingerprint && $0.host == host } ?? false
    }

    func recordGrant(for host: String) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(buildFingerprint)\n\(host)".write(to: fileURL, atomically: true, encoding: .utf8)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try url.setResourceValues(values)
        } catch {
            clear()
        }
    }

    private var record: (fingerprint: String, host: String)? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2 else { return nil }
        return (String(lines[0]), String(lines[1]))
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
