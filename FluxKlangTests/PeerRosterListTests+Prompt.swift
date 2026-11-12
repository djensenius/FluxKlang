import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerRosterListTests {
    @Test("The prompt reads Pair request from Remote C")
    func promptText() throws {
        let prompt = try PeerRosterPairPrompt.make(try Fixture.request(label: "Remote C", role: .remoteController))
        #expect(prompt.peerName == "Remote C")
        #expect(prompt.requestedRole == .remoteController)
        #expect(prompt.title == "Pair request from Remote C")
        #expect(prompt.detail == "Requested role: Remote controller")
        #expect(prompt.accessibilityLabel == "Pair request from Remote C. Requested role: Remote controller.")
    }

    @Test("Choices are Allow then Deny, and Escape denies")
    func promptChoices() throws {
        let prompt = try PeerRosterPairPrompt.make(try Fixture.request(label: "Remote C", role: .remoteController))
        #expect(prompt.choices == [.allow, .deny])
        #expect(prompt.choices.map(\.title) == ["Allow", "Deny"])
        #expect(prompt.escapeChoice == .deny)
        #expect(PeerRosterPromptChoice.allCases.count == 2)
    }

    @Test("The prompt has no default or selected choice")
    func promptHasNoDefault() throws {
        let prompt = try PeerRosterPairPrompt.make(try Fixture.request(label: "Remote C", role: .observer))
        let labels = Mirror(reflecting: prompt).children.map(\.label)
        #expect(labels == ["peerName", "requestedRole", "choices", "escapeChoice"])
        #expect(!((PeerRosterPromptChoice.allow as Any) is any RawRepresentable))
    }

    @Test("The requested role is not the role a roster row shows")
    func requestedRoleIsNotGranted() throws {
        let prompt = try PeerRosterPairPrompt.make(try Fixture.request(label: "Remote C", role: .remoteController))
        let observerPrompt = try PeerRosterPairPrompt.make(try Fixture.request(label: "Remote C", role: .observer))
        #expect(observerPrompt.detail == "Requested role: Observer")
        let granted = try Fixture.record(1, "Remote C", role: .observer)
        let row = try #require(try PeerRosterList.make(records: [granted]).rows.first)
        #expect(prompt.requestedRole == .remoteController)
        #expect(row.roleText == "Observer")
    }

    @Test("Invalid labels are refused, and 64 bytes are accepted")
    func invalidLabels() throws {
        let refused = ["", String(repeating: "a", count: 65), " Remote C", "Remote\u{7}C"]
        for label in refused {
            #expect(throws: PeerRosterRefusal.invalidLabel) {
                try PeerRosterPairPrompt.make(try Fixture.request(label: label, role: .observer))
            }
        }
        let longest = String(repeating: "a", count: 64)
        #expect(try PeerRosterPairPrompt.make(try Fixture.request(label: longest, role: .observer)).peerName == longest)
        let table = refused + [longest, "Remote C", "\u{E9}", "Remote C ", "Re\u{200B}mote"]
        for label in table {
            let request = try Fixture.request(label: label, role: .observer)
            let accepted = (try? PeerRosterPairPrompt.make(request)) != nil
            #expect(accepted == PeerPairingLabelRule.isValid(label))
        }
    }

    @Test("Fixed texts are pinned in one place")
    func fixedTexts() {
        #expect(PeerRosterText.revoke == "Revoke")
        #expect(PeerRosterText.disconnected == "Disconnected")
        #expect(PeerRosterText.noPairedPeers == "No paired peers")
        #expect(PeerRosterText.connected(epoch: 1) == "Connected (epoch 1)")
        #expect(PeerRosterText.role(.remoteController) == "Remote controller")
        #expect(PeerRosterText.role(.observer) == "Observer")
        #expect(PeerRosterText.allow == "Allow")
        #expect(PeerRosterText.deny == "Deny")
    }
}
