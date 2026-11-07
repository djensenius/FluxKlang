import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension TimecodeMachineTests {
    @Test func machineEmptyPolicyRefusesEveryAddressedCommandWithItsClass() throws {
        let receiver = try Self.deviceID(0x21)
        for (command, commandClass) in try Self.commandsWithClasses() {
            let message = MMCMessage(deviceID: receiver, command: command)
            let decision = MMCIntentGate.evaluate(message: message, policy: .denyAll, receiver: receiver)
            #expect(decision == .refused(.notAuthorized(commandClass)))
        }
    }

    @Test func machineAuthorizedMessageBecomesAnIntentWithExactFields() throws {
        let receiver = try Self.deviceID(0x21)
        let policy = try Self.policy(MMCCommandClass.allCases.map { Self.entry($0, .device(receiver)) })
        for (command, commandClass) in try Self.commandsWithClasses() {
            let message = MMCMessage(deviceID: receiver, command: command)
            let decision = MMCIntentGate.evaluate(message: message, policy: policy, receiver: receiver)
            guard case let .intent(intent) = decision else {
                Issue.record("expected an intent for \(command)")
                continue
            }
            #expect(intent.deviceID == receiver)
            #expect(intent.command == command)
            #expect(intent.commandClass == commandClass)
        }
    }

    @Test func machineOnlyTheGrantedClassBecomesAnIntent() throws {
        let receiver = try Self.deviceID(0x21)
        let policy = try Self.policy([Self.entry(.play)])
        let play = MMCMessage(deviceID: receiver, command: .play)
        let record = MMCMessage(deviceID: receiver, command: .recordStrobe)
        let decision = MMCIntentGate.evaluate(message: play, policy: policy, receiver: receiver)
        guard case let .intent(intent) = decision else {
            Issue.record("play must be admitted")
            return
        }
        #expect(intent.command == .play)
        #expect(MMCIntentGate.evaluate(message: record, policy: policy, receiver: receiver)
            == .refused(.notAuthorized(.record)))
    }

    @Test func machineRecordIntentsKeepTheirSpecificCommand() throws {
        let receiver = try Self.deviceID(0x21)
        let policy = try Self.policy([Self.entry(.record)])
        for command in [MMCCommand.recordStrobe, .recordExit] {
            let message = MMCMessage(deviceID: receiver, command: command)
            let decision = MMCIntentGate.evaluate(message: message, policy: policy, receiver: receiver)
            guard case let .intent(intent) = decision else {
                Issue.record("record must be admitted")
                continue
            }
            #expect(intent.command == command)
            #expect(intent.commandClass == .record)
        }
    }

    @Test func machineMessageForAnotherDeviceIsIgnoredNotRefused() throws {
        let receiver = try Self.deviceID(0x21)
        let other = try Self.deviceID(0x22)
        let permissive = try Self.policy(MMCCommandClass.allCases.map { Self.entry($0, .any) })
        for (command, _) in try Self.commandsWithClasses() {
            let message = MMCMessage(deviceID: other, command: command)
            #expect(MMCIntentGate.evaluate(message: message, policy: .denyAll, receiver: receiver) == .ignored)
            #expect(MMCIntentGate.evaluate(message: message, policy: permissive, receiver: receiver) == .ignored)
        }
    }

    @Test func machineAllCallMessageIsEvaluatedForEveryReceiver() throws {
        let receiver = try Self.deviceID(0x21)
        let message = MMCMessage(deviceID: .allCall, command: .stop)
        #expect(MMCIntentGate.evaluate(message: message, policy: .denyAll, receiver: receiver)
            == .refused(.notAuthorized(.stop)))
        let exact = try Self.policy([Self.entry(.stop, .device(receiver))])
        #expect(MMCIntentGate.evaluate(message: message, policy: exact, receiver: receiver)
            == .refused(.notAuthorized(.stop)))
        let broadcast = try Self.policy([Self.entry(.stop, .device(.allCall))])
        guard case let .intent(intent) = MMCIntentGate.evaluate(message: message, policy: broadcast, receiver: receiver)
        else {
            Issue.record("an explicit all-call entry must admit an all-call message")
            return
        }
        #expect(intent.deviceID == .allCall)
        #expect(intent.command == .stop)
    }

    @Test func machinePolicySelectorsAreCheckedAgainstTheMessageDeviceID() throws {
        let receiver = try Self.deviceID(0x21)
        let wrong = try Self.policy([Self.entry(.play, .device(try Self.deviceID(0x22)))])
        let message = MMCMessage(deviceID: receiver, command: .play)
        #expect(MMCIntentGate.evaluate(message: message, policy: wrong, receiver: receiver)
            == .refused(.notAuthorized(.play)))
    }

    @Test func machineLocateIntentCarriesTheExactTarget() throws {
        let receiver = try Self.deviceID(0x21)
        let target = try Self.locateTarget(subframes: 99, colorFrame: true)
        let message = MMCMessage(deviceID: receiver, command: .locate(target))
        let policy = try Self.policy([Self.entry(.locate)])
        guard case let .intent(intent) = MMCIntentGate.evaluate(message: message, policy: policy, receiver: receiver)
        else {
            Issue.record("locate must be admitted")
            return
        }
        #expect(intent.locateTarget == target)
        #expect(intent.locateTarget?.time.frames == 4)
        #expect(intent.locateTarget?.time.rate == .fps25)
        #expect(intent.locateTarget?.subframes == 99)
        #expect(intent.locateTarget?.colorFrame == true)
        #expect(intent.command == .locate(target))
    }

    @Test func machineNonLocateIntentsHaveNoLocateTarget() throws {
        let receiver = try Self.deviceID(0x21)
        let policy = try Self.policy([Self.entry(.play)])
        let message = MMCMessage(deviceID: receiver, command: .play)
        guard case let .intent(intent) = MMCIntentGate.evaluate(message: message, policy: policy, receiver: receiver)
        else {
            Issue.record("play must be admitted")
            return
        }
        #expect(intent.locateTarget == nil)
    }

    @Test func machineIntentIsAPureValueEqualToAFreshlyBuiltOne() throws {
        let receiver = try Self.deviceID(0x21)
        let policy = try Self.policy([Self.entry(.locate), Self.entry(.play)])
        let target = try Self.locateTarget()
        let other = try Self.locateTarget(subframes: 41)
        let first = MMCIntentGate.evaluate(message: MMCMessage(deviceID: receiver, command: .locate(target)),
                                           policy: policy, receiver: receiver)
        let second = MMCIntentGate.evaluate(message: MMCMessage(deviceID: receiver, command: .locate(target)),
                                            policy: policy, receiver: receiver)
        let different = MMCIntentGate.evaluate(message: MMCMessage(deviceID: receiver, command: .locate(other)),
                                               policy: policy, receiver: receiver)
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
        #expect(first != different)
        #expect(MMCIntent.authorized(message: MMCMessage(deviceID: receiver, command: .play), by: policy)
            == MMCIntent.authorized(message: MMCMessage(deviceID: receiver, command: .play), by: policy))
        #expect(MMCIntent.authorized(message: MMCMessage(deviceID: receiver, command: .stop), by: policy) == nil)
    }

    @Test func machineGateDecisionsLeaveMessageAndPolicyUnchanged() throws {
        let receiver = try Self.deviceID(0x21)
        let policy = try Self.policy([Self.entry(.play)])
        let policyCopy = policy
        let message = MMCMessage(deviceID: receiver, command: .rewind)
        let messageCopy = message
        #expect(MMCIntentGate.evaluate(message: message, policy: policy, receiver: receiver)
            == .refused(.notAuthorized(.rewind)))
        #expect(policy == policyCopy)
        #expect(message == messageCopy)
    }

    @Test func machineDecodedWireBytesFlowThroughTheGateWithoutReparsing() throws {
        let receiver = try Self.deviceID(0x21)
        let event = MIDI1Event.sysEx(payload: [0x7F, 0x21, 0x06, 0x02])
        let decoded = try #require(try MMCMessage.decode(event, receiver: receiver))
        let policy = try Self.policy([Self.entry(.play, .device(receiver))])
        guard case let .intent(intent) = MMCIntentGate.evaluate(message: decoded, policy: policy, receiver: receiver)
        else {
            Issue.record("decoded play must be admitted")
            return
        }
        #expect(intent.command == .play)
        #expect(intent.deviceID == receiver)
    }
}
