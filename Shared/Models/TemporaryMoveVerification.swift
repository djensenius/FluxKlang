//
//  TemporaryMoveVerification.swift
//  FluxKlang
//

import Foundation

struct TemporaryMoveRoutingImpact: Hashable, Sendable {
    var settings: [WingSetting]
    var expectedConfirmations: [WingSetting]

    var summary: String {
        if expectedConfirmations.isEmpty {
            return "\(settings.count) routing settings; no affected source nodes are currently compiled."
        }
        return """
        \(settings.count) routing settings; \(expectedConfirmations.count) affected source values will be checked.
        """
    }

    static func build(
        settings: [WingSetting],
        inputConnectors: Set<Int>,
        outputConnectors: Set<Int>
    ) -> TemporaryMoveRoutingImpact {
        let byAddress = Dictionary(settings.map { ($0.address, $0) }, uniquingKeysWith: { _, latest in latest })
        var expected: [WingSetting] = []
        for output in outputConnectors {
            append(WingAddress.outputSourceGroup(output), from: byAddress, to: &expected)
            append(WingAddress.outputSourceIndex(output), from: byAddress, to: &expected)
        }
        for channel in 1...WingNodeKind.channel.count {
            let groupAddress = WingAddress.channelSourceGroup(channel)
            let indexAddress = WingAddress.channelSourceIndex(channel)
            guard byAddress[groupAddress]?.value.stringValue == WingSourceGroup.local.rawValue,
                  let index = byAddress[indexAddress]?.value.intValue.map(Int.init),
                  inputConnectors.contains(index) else { continue }
            append(groupAddress, from: byAddress, to: &expected)
            append(indexAddress, from: byAddress, to: &expected)
        }
        return TemporaryMoveRoutingImpact(
            settings: settings,
            expectedConfirmations: unique(expected)
        )
    }

    // Both sides of the connector transition are required to emit safe clears.
    // swiftlint:disable:next function_parameter_count
    static func transition(
        from previousSettings: [WingSetting],
        to candidateSettings: [WingSetting],
        previousInputConnectors: Set<Int>,
        previousOutputConnectors: Set<Int>,
        desiredInputConnectors: Set<Int>,
        desiredOutputConnectors: Set<Int>
    ) -> TemporaryMoveRoutingImpact {
        var settings = candidateSettings
        var channelClears: [WingSetting] = []
        let candidateByAddress = Dictionary(
            candidateSettings.map { ($0.address, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for output in previousOutputConnectors.subtracting(desiredOutputConnectors) {
            settings.append(contentsOf: WingOutputSource.none.settings(forOutput: output))
        }
        for channel in affectedChannels(in: previousSettings, connectors: previousInputConnectors) {
            guard candidateByAddress[WingAddress.channelSourceGroup(channel)] == nil else { continue }
            channelClears.append(contentsOf: WingSource.none.settings(forChannel: channel))
        }
        settings.append(contentsOf: channelClears)
        var impact = build(
            settings: settings,
            inputConnectors: previousInputConnectors.union(desiredInputConnectors),
            outputConnectors: previousOutputConnectors.union(desiredOutputConnectors)
        )
        impact.expectedConfirmations = unique(impact.expectedConfirmations + channelClears)
        return impact
    }

    private static func append(
        _ address: String,
        from settings: [String: WingSetting],
        to result: inout [WingSetting]
    ) {
        if let setting = settings[address] {
            result.append(setting)
        }
    }

    private static func unique(_ settings: [WingSetting]) -> [WingSetting] {
        var seen: Set<String> = []
        return settings.filter { seen.insert($0.address).inserted }
    }

    private static func affectedChannels(
        in settings: [WingSetting],
        connectors: Set<Int>
    ) -> [Int] {
        let byAddress = Dictionary(settings.map { ($0.address, $0) }, uniquingKeysWith: { _, latest in latest })
        return (1...WingNodeKind.channel.count).filter { channel in
            let group = byAddress[WingAddress.channelSourceGroup(channel)]?.value.stringValue
            let index = byAddress[WingAddress.channelSourceIndex(channel)]?.value.intValue.map(Int.init)
            return group == WingSourceGroup.local.rawValue && index.map(connectors.contains) == true
        }
    }
}

enum TemporaryMoveVerifier {
    static func verify(
        expected: [WingSetting],
        confirmedValues: [String: WingValue],
        previous: TemporaryMoveVerification? = nil,
        checkedAt: Date = Date()
    ) -> TemporaryMoveVerification {
        guard !expected.isEmpty else {
            return TemporaryMoveVerification(
                state: .partiallyVerified,
                checkedAt: checkedAt,
                details: "No affected output or channel-source nodes are present in the current compiled patch."
            )
        }
        let confirmed = expected.filter { confirmedValues[$0.address] == $0.value }
        let mismatched = expected.filter {
            guard let value = confirmedValues[$0.address] else { return false }
            return value != $0.value
        }
        let missingCount = expected.count - confirmed.count - mismatched.count
        let state: TemporaryMoveVerificationState
        let details: String
        if !mismatched.isEmpty {
            let wasHealthy = previous?.state == .verified
                || previous?.state == .partiallyVerified
                || previous?.state == .driftDetected
            state = wasHealthy ? .driftDetected : .failed
            details = "\(mismatched.count) confirmed value(s) differ from the expected routing."
        } else if missingCount > 0 {
            state = .partiallyVerified
            details = """
            \(confirmed.count) of \(expected.count) values were confirmed; \(missingCount) replies are unavailable.
            """
        } else {
            state = .verified
            details = "All \(expected.count) affected routing values match confirmed console replies."
        }
        return TemporaryMoveVerification(
            state: state,
            checkedAt: checkedAt,
            expectedCount: expected.count,
            confirmedCount: confirmed.count,
            details: details
        )
    }
}
