import Foundation
import Testing
@testable import FluxKlang

private let host = HostID(validated: "host.control")
private let hostEpoch = HostEpoch(host: host, generation: .initial)
private let connection = ConnectionEpoch(connection: ConnectionID(validated: "connection.remote"),
                                         host: host, generation: .initial)
private let permission = PermissionFingerprint(rawValue: "permissions.current")
private let parameter = ParameterID(validated: "parameter.test")

private func operation(for controlClass: ControlClass) -> CommandOperation {
    switch controlClass {
    case .live, .hazardous: .set(parameter, .init(value: 0.5, unit: .normalized))
    case .structural: .bind(RouteID(validated: "route.test"))
    case .safety: .panic
    case .proposal: .propose(DraftID(validated: "draft.test"))
    }
}

private func intent(_ controlClass: ControlClass, host currentHost: HostEpoch = hostEpoch,
                    connection currentConnection: ConnectionEpoch? = connection,
                    revisions: CommandRevisions = CommandRevisions(), origin: CommandOrigin = .human,
                    operation explicit: CommandOperation? = nil) throws -> CommandIntent {
    try CommandIntent(.init(
        id: CommandID(validated: "command.test"), commandClass: controlClass, origin: origin,
        hostEpoch: currentHost, connectionEpoch: currentConnection, revisions: revisions,
        operation: explicit ?? operation(for: controlClass), permission: permission
    ))
}

private func context(_ controlClass: ControlClass, scopes: Set<CommandScope>? = nil,
                     revisions: CommandRevisions = CommandRevisions(),
                     connection currentConnection: ConnectionEpoch? = connection) throws -> AdmissionContext {
    let descriptor = try ParameterDescriptor(.init(
        id: parameter, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: 0.8,
        curve: .linear, ramp: ParameterRamp(.init(kind: .linear, minimumMilliseconds: 10, maximumMilliseconds: 100)),
        controlClass: controlClass == .hazardous ? .hazardous : .live, verification: .reported
    ))
    return AdmissionContext(
        hostEpoch: hostEpoch, connectionEpoch: currentConnection, revisions: revisions, permission: permission,
        allowedScopes: scopes ?? [operation(for: controlClass).scope], allowedClasses: [controlClass],
        catalog: try ParameterCatalog([descriptor])
    )
}

extension ControlContractTests {
    struct Commands {
        @Test(arguments: ControlClass.allCases)
        func everyClassChecksHostConnectionScopeAndRevisions(controlClass: ControlClass) throws {
            let current = try context(controlClass)
            #expect(try CommandAdmission.admit(intent(controlClass), in: current) == .admitted)
            let oldHost = HostEpoch(host: host, generation: try Generation.initial.next())
            #expect(try CommandAdmission.admit(intent(controlClass, host: oldHost), in: current)
                == .refused(.stale(.hostEpoch)))
            let oldConnection = ConnectionEpoch(connection: connection.connection, host: host,
                                                generation: try Generation.initial.next())
            #expect(try CommandAdmission.admit(intent(controlClass, connection: oldConnection), in: current)
                == .refused(.stale(.connectionEpoch)))
            #expect(try CommandAdmission.admit(intent(controlClass), in: context(controlClass, scopes: []))
                == .refused(.rejected(.scopeDenied)))
            for key in [\CommandRevisions.patch, \.capability, \.permission, \.parameter, \.graph] {
                var revisions = CommandRevisions()
                revisions[keyPath: key] = try ContractRevision.initial.next()
                #expect(try CommandAdmission.admit(intent(controlClass, revisions: revisions), in: current)
                    == .refused(.rejected(.revisionChanged)))
            }
        }

        @Test func connectionsAndHostsAreSeparateIdentities() throws {
            let other = ConnectionEpoch(connection: ConnectionID(validated: "connection.other"),
                                        host: host, generation: .initial)
            #expect(try CommandAdmission.admit(intent(.live, connection: other), in: context(.live))
                == .refused(.stale(.connectionEpoch)))
            #expect(try CommandAdmission.admit(intent(.live, connection: nil), in: context(.live))
                == .refused(.stale(.connectionEpoch)))
            #expect(try CommandAdmission.admit(intent(.live, connection: nil), in: context(.live, connection: nil))
                == .admitted)
        }

        @Test func assistantLocalityNeverGrantsActivationAndClassCannotBeRelabelled() throws {
            #expect(try CommandAdmission.admit(intent(.live, origin: .assistant), in: context(.live))
                == .refused(.rejected(.permissionDenied)))
            #expect(try CommandAdmission.admit(intent(.proposal, origin: .assistant), in: context(.proposal))
                == .admitted)
            #expect(try CommandAdmission.admit(intent(.live), in: context(.hazardous))
                == .refused(.rejected(.permissionDenied)))
            let ramp = CommandOperation.ramp(parameter, .init(value: 0.7, unit: .normalized), milliseconds: 101)
            #expect(try CommandAdmission.admit(intent(.live, operation: ramp), in: context(.live))
                == .refused(.rejected(.invalidValue(.invalidRamp))))
        }

        @Test(arguments: [Int64(-1), Int64.min])
        func negativeLocateTicksRejectConstructionAndDecoding(ticks: Int64) throws {
            #expect(throws: ControlValidationError.self) {
                try intent(.live, operation: .locate(ticks: ticks))
            }
            let valid = try intent(.live, operation: .locate(ticks: 0))
            let data = try ContractCoding.makeEncoder().encode(valid)
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["operation"] = ["locate": ["ticks": ticks]]
            #expect(throws: ControlValidationError.self) {
                try ContractCoding.decode(CommandIntent.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }

        @Test(arguments: [Int64(0), Int64.max])
        func nonnegativeLocateBoundsRoundTripAndAdmit(ticks: Int64) throws {
            let request = try intent(.live, operation: .locate(ticks: ticks))
            let data = try ContractCoding.makeEncoder().encode(request)
            let decoded = try ContractCoding.decode(CommandIntent.self, from: data)
            #expect(try CommandAdmission.admit(decoded, in: context(.live, scopes: [.transport])) == .admitted)
        }

        @Test func commandEnvelopePreservesNestedOptionalDataAndRejectsRequiredFeatures() throws {
            let document = try CommandDocument(revision: .initial, payload: CommandPayload(intent: intent(.live)))
            let data = try ContractCoding.makeEncoder().encode(document)
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var payload = try #require(object["payload"] as? [String: Any])
            var intent = try #require(payload["intent"] as? [String: Any])
            var revisions = try #require(intent["revisions"] as? [String: Any])
            revisions["future"] = ["nested": true]
            intent["revisions"] = revisions
            payload["intent"] = intent
            object["payload"] = payload
            let decoded = try ContractCoding.decode(CommandDocument.self,
                from: JSONSerialization.data(withJSONObject: object))
            let encoded = try ContractCoding.makeEncoder().encode(decoded)
            #expect(String(data: encoded, encoding: .utf8)?.contains("\"future\":{\"nested\":true}") == true)
            object["requiredFeatures"] = ["future-authority"]
            #expect(throws: ControlValidationError.self) {
                try ContractCoding.decode(CommandDocument.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
    }
}
