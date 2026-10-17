//
//  StudioOutputDefaults.swift
//  FluxKlang
//
//  Loads the editable, bundled starting map for physical WING outputs.
//

import Foundation

struct StudioOutputDefaults: Codable, Sendable {
    struct Output: Codable, Sendable {
        var bank: WingOutputConnectorBank
        var connector: Int
        var equipmentName: String?
        var inputPort: Int?
        var destinationName: String?
    }

    var outputs: [Output]
    var version: Int

    static func bundled() -> StudioOutputDefaults? {
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        for bundle in bundles {
            guard let url = bundle.url(
                forResource: "studio-connections.defaults",
                withExtension: "json"
            ),
            let data = try? Data(contentsOf: url),
            let defaults = try? JSONDecoder().decode(StudioOutputDefaults.self, from: data) else {
                continue
            }
            return defaults
        }
        return nil
    }

    func applying(to home: StudioHomeConnections, equipment: [Equipment]) -> StudioHomeConnections {
        var result = home
        let equipmentByName = Dictionary(
            equipment.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for output in outputs {
            let connector = WingOutputConnector(bank: output.bank, index: output.connector)
            guard output.bank.connectorRange.contains(output.connector) else {
                continue
            }
            result.outputs.removeAll { $0.outputConnector == connector }
            if let destinationName = output.destinationName {
                result.outputs.append(StudioOutputConnection(
                    bank: output.bank,
                    connector: output.connector,
                    destinationName: destinationName
                ))
            } else if let equipmentName = output.equipmentName,
                      let inputPort = output.inputPort,
                      let device = equipmentByName[equipmentName],
                      device.inputs.indices.contains(inputPort) {
                result.outputs.removeAll {
                    $0.equipmentID == device.id && $0.inputPort == inputPort
                }
                result.outputs.append(StudioOutputConnection(
                    bank: output.bank,
                    connector: output.connector,
                    equipmentID: device.id,
                    inputPort: inputPort
                ))
            }
        }
        result.outputs.sort {
            ($0.bank.rawValue, $0.connector) < ($1.bank.rawValue, $1.connector)
        }
        return result
    }
}

private final class BundleToken {}

extension StudioHomeConnections {
    mutating func applyConfirmedOutputDefaults(
        _ defaults: StudioOutputDefaults,
        equipment: [Equipment]
    ) {
        self = defaults.applying(to: self, equipment: equipment)
    }
}
