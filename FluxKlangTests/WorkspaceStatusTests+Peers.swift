//
//  WorkspaceStatusTests+Peers.swift
//  FluxKlangTests
//
//  The Peers segment of the status strip (#99 W3): the words per reconnect phase, the stale-command note,
//  the three-peer summary bound, the worst-severity rule and the Local Network permission effect.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WorkspaceStatusTests {
    /// What VoiceOver reads for Peers while Local Network is confirmed off: the cause, then the reassurance.
    static let peersOffLabel =
        "Peers: Peer control unavailable, Local Network denied; local manual use unaffected"

    static func peersSegment(
        _ rows: [WorkspaceStatusPeer], localNetwork: PermissionStatus = .granted
    ) throws -> WorkspaceStatusSegment {
        try segment(.peers) {
            $0.peers = rows
            $0.permissions = Self.permissions(localNetwork: localNetwork)
        }
    }

    /// `P1`... `Pn`, each synced and resumed, `Pk` on a session whose connection epoch is `k`.
    static func syncedPeers(_ count: Int) throws -> [WorkspaceStatusPeer] {
        var peers: [WorkspaceStatusPeer] = []
        for number in 0..<count {
            let session = try Self.session(epoch: number + 1)
            peers.append(Self.peer("P\(number + 1)", .synced(session, awaitingResume: false)))
        }
        return peers
    }

    @Test func noPeersSaysNoPeers() throws {
        let none = try Self.peersSegment([])
        Self.expectSegment(none, text: "No peers", label: "Peers: No peers", severity: .normal)
    }

    @Test func connectedPeerShowsItsConnectionEpochAtAttention() throws {
        let remote = try Self.session(epoch: 4)
        let connected = try Self.peersSegment([Self.peer("Remote C", .connected(remote))])
        Self.expectSegment(
            connected, text: "Remote C connected (epoch 4)", label: "Peers: Remote C connected (epoch 4)",
            severity: .attention
        )
        #expect(connected.glyphName == "exclamationmark.triangle")
    }

    @Test func syncedPeerShowsItsEpochAtNormalUntilItAwaitsResume() throws {
        let remote = try Self.session(epoch: 4)
        let synced = try Self.peersSegment([Self.peer("Remote C", .synced(remote, awaitingResume: false))])
        Self.expectSegment(
            synced, text: "Remote C connected (epoch 4)", label: "Peers: Remote C connected (epoch 4)",
            severity: .normal
        )
        let awaiting = try Self.peersSegment([Self.peer("Remote C", .synced(remote, awaitingResume: true))])
        Self.expectSegment(
            awaiting, text: "Remote C resyncing", label: "Peers: Remote C resyncing", severity: .attention
        )
    }

    @Test func resyncingPeerSaysResyncingAtAttention() throws {
        let remote = try Self.session(epoch: 5)
        let resyncing = try Self.peersSegment([Self.peer("Remote C", .resyncing(remote))])
        Self.expectSegment(
            resyncing, text: "Remote C resyncing", label: "Peers: Remote C resyncing", severity: .attention
        )
        #expect(resyncing.glyphName == "exclamationmark.triangle")
    }

    @Test func disconnectedPeerIsAnErrorAndALostItem() throws {
        let remote = try Self.session(epoch: 5)
        let lost = try Self.peersSegment([Self.peer("Remote C", .disconnected(remote))])
        Self.expectSegment(
            lost, text: "Remote C disconnected", label: "Peers: Remote C disconnected", severity: .error,
            lostItems: ["Remote C"]
        )
        #expect(lost.glyphName == "exclamationmark.octagon")
    }

    @Test func epochShownIsTheConnectionEpochNotTheHostEpoch() throws {
        let nineOverTwo = try Self.session(epoch: 9, hostEpoch: 2)
        let oneOverFive = try Self.session(epoch: 1, hostEpoch: 5)
        let newest = try Self.session(epoch: Generation.maximumValue, hostEpoch: 3)
        let rows = [
            Self.peer("A", .connected(nineOverTwo)), Self.peer("B", .connected(oneOverFive)),
            Self.peer("C", .connected(newest))
        ]
        let peers = try Self.peersSegment(rows)
        let expected = "A connected (epoch 9), B connected (epoch 1), C connected (epoch 9007199254740991)"
        #expect(peers.text == expected)
        #expect(peers.label == "Peers: \(expected)")
    }

    @Test func staleCommandsAppendASingularOrPluralNoteNamingThePeer() throws {
        let remote = try Self.session(epoch: 4)
        let one = try Self.peersSegment([Self.peer("Remote C", .connected(remote), stale: 1)])
        Self.expectSegment(
            one, text: "Remote C connected (epoch 4), Remote C: 1 stale command discarded",
            label: "Peers: Remote C connected (epoch 4), Remote C: 1 stale command discarded",
            severity: .attention
        )
        let two = try Self.peersSegment([Self.peer("Remote C", .connected(remote), stale: 2)])
        #expect(two.text == "Remote C connected (epoch 4), Remote C: 2 stale commands discarded")
        let none = try Self.peersSegment([Self.peer("Remote C", .connected(remote), stale: 0)])
        #expect(none.text == "Remote C connected (epoch 4)")
        let many = try Self.peersSegment([Self.peer("Remote C", .connected(remote), stale: 1_000_000)])
        #expect(many.text == "Remote C connected (epoch 4), Remote C: 1000000 stale commands discarded")
    }

    @Test func staleCommandsRaiseASyncedPeerToAttentionAndNeverLowerAnError() throws {
        let remote = try Self.session(epoch: 4)
        let synced = try Self.peersSegment([Self.peer("Remote C", .synced(remote, awaitingResume: false), stale: 1)])
        #expect(synced.text == "Remote C connected (epoch 4), Remote C: 1 stale command discarded")
        #expect(synced.severity == .attention)
        #expect(synced.lostItems.isEmpty)
        let lost = try Self.peersSegment([Self.peer("Remote C", .disconnected(remote), stale: 3)])
        Self.expectSegment(
            lost, text: "Remote C disconnected, Remote C: 3 stale commands discarded",
            label: "Peers: Remote C disconnected, Remote C: 3 stale commands discarded", severity: .error,
            lostItems: ["Remote C"]
        )
    }

    @Test func peersKeepInputOrderAndTheSegmentTakesTheWorstSeverity() throws {
        let one = try Self.session(epoch: 1)
        let two = try Self.session(epoch: 2)
        let three = try Self.session(epoch: 3)
        let rows = [
            Self.peer("Zed", .synced(one, awaitingResume: false)), Self.peer("Abe", .resyncing(two)),
            Self.peer("Moe", .disconnected(three))
        ]
        let peers = try Self.peersSegment(rows)
        Self.expectSegment(
            peers, text: "Zed connected (epoch 1), Abe resyncing, Moe disconnected",
            label: "Peers: Zed connected (epoch 1), Abe resyncing, Moe disconnected", severity: .error,
            lostItems: ["Moe"]
        )
        let reversed = try Self.peersSegment(Array(rows.reversed()))
        #expect(reversed.text == "Moe disconnected, Abe resyncing, Zed connected (epoch 1)")
        #expect(reversed.severity == .error)
        let attention = try Self.peersSegment(Array(rows.prefix(2)))
        #expect(attention.severity == .attention)
        #expect(attention.lostItems.isEmpty)
        let normal = try Self.peersSegment(Array(rows.prefix(1)))
        #expect(normal.severity == .normal)
    }

    @Test func peerTextListsThreePeersThenAndNMore() throws {
        let threeRows = try Self.syncedPeers(3)
        let three = try Self.peersSegment(threeRows)
        #expect(three.text == "P1 connected (epoch 1), P2 connected (epoch 2), P3 connected (epoch 3)")
        let fourRows = try Self.syncedPeers(4)
        let four = try Self.peersSegment(fourRows)
        #expect(four.text == "P1 connected (epoch 1), P2 connected (epoch 2), P3 connected (epoch 3), and 1 more")
        let fiveRows = try Self.syncedPeers(5)
        let five = try Self.peersSegment(fiveRows)
        #expect(five.text == "P1 connected (epoch 1), P2 connected (epoch 2), P3 connected (epoch 3), and 2 more")
        #expect(five.label == "Peers: \(five.text)")
        let twoRows = try Self.syncedPeers(2)
        let two = try Self.peersSegment(twoRows)
        #expect(two.text == "P1 connected (epoch 1), P2 connected (epoch 2)")
    }

    @Test func aDisconnectedPeerBeyondTheCapStillSetsTheSeverityAndTheLostItems() throws {
        var rows = try Self.syncedPeers(4)
        let hiddenSession = try Self.session(epoch: 7)
        rows.append(Self.peer("Hidden", .disconnected(hiddenSession)))
        let peers = try Self.peersSegment(rows)
        let visible = "P1 connected (epoch 1), P2 connected (epoch 2), P3 connected (epoch 3)"
        #expect(peers.text == "\(visible), and 2 more, 1 disconnected")
        #expect(peers.severity == .error)
        #expect(peers.lostItems == ["Hidden"])
    }

    @Test func aHiddenDisconnectedPeerAddsItsCountToTheLabel() throws {
        let visible = "P1 connected (epoch 1), P2 connected (epoch 2), P3 connected (epoch 3)"
        let gone = try Self.session(epoch: 9)
        let synced = try Self.syncedPeers(3)
        let oneGone = try Self.peersSegment(synced + [Self.peer("Gone", .disconnected(gone))])
        Self.expectSegment(
            oneGone, text: "\(visible), and 1 more, 1 disconnected",
            label: "Peers: \(visible), and 1 more, 1 disconnected", severity: .error, lostItems: ["Gone"]
        )
        let twoGone = try Self.peersSegment(
            synced + [Self.peer("Gone", .disconnected(gone)), Self.peer("Away", .disconnected(gone))]
        )
        #expect(twoGone.text == "\(visible), and 2 more, 2 disconnected")
        #expect(twoGone.label == "Peers: \(visible), and 2 more, 2 disconnected")
        #expect(twoGone.lostItems == ["Gone", "Away"])
        let quiet = Self.peer("Quiet", .synced(gone, awaitingResume: false))
        let mixed = try Self.peersSegment(synced + [quiet, Self.peer("Gone", .disconnected(gone))])
        #expect(mixed.text == "\(visible), and 2 more, 1 disconnected")
        #expect(mixed.lostItems == ["Gone"])
        let withStale = try Self.peersSegment(synced + [Self.peer("Gone", .disconnected(gone), stale: 2)])
        #expect(withStale.text == "\(visible), and 1 more, 1 disconnected")
    }

    @Test func aHiddenPeerThatIsNotLostAddsNoSuffix() throws {
        let visible = "P1 connected (epoch 1), P2 connected (epoch 2), P3 connected (epoch 3)"
        let away = try Self.session(epoch: 8)
        let synced = try Self.syncedPeers(3)
        let resyncing = try Self.peersSegment(synced + [Self.peer("Away", .resyncing(away))])
        Self.expectSegment(
            resyncing, text: "\(visible), and 1 more", label: "Peers: \(visible), and 1 more", severity: .attention
        )
        let stale = try Self.peersSegment(synced + [Self.peer("Away", .connected(away), stale: 2)])
        #expect(stale.text == "\(visible), and 1 more")
        let both = [Self.peer("Away", .resyncing(away)), Self.peer("Back", .resyncing(away))]
        let two = try Self.peersSegment(synced + both)
        #expect(two.text == "\(visible), and 2 more")
    }

    @Test func aListedDisconnectedPeerIsNotCountedAgainAsAHiddenOne() throws {
        let one = try Self.session(epoch: 1)
        let two = try Self.session(epoch: 2)
        let three = try Self.session(epoch: 3)
        let four = try Self.session(epoch: 4)
        let rows = [
            Self.peer("P1", .synced(one, awaitingResume: false)), Self.peer("P2", .disconnected(two)),
            Self.peer("P3", .synced(three, awaitingResume: false)),
            Self.peer("P4", .synced(four, awaitingResume: false))
        ]
        let hiddenSynced = try Self.peersSegment(rows)
        let listed = "P1 connected (epoch 1), P2 disconnected, P3 connected (epoch 3)"
        Self.expectSegment(
            hiddenSynced, text: "\(listed), and 1 more", label: "Peers: \(listed), and 1 more", severity: .error,
            lostItems: ["P2"]
        )
        let exactlyThree = try Self.peersSegment(Array(rows.prefix(3)))
        #expect(exactlyThree.text == listed)
        #expect(exactlyThree.label == "Peers: \(listed)")
        let hiddenLost = try Self.peersSegment(rows + [Self.peer("P5", .disconnected(four))])
        #expect(hiddenLost.text == "\(listed), and 2 more, 1 disconnected")
        #expect(hiddenLost.lostItems == ["P2", "P5"])
    }

    @Test func localNetworkStatusEffectsOverAllEightStates() throws {
        let rows = try Self.syncedPeers(2)
        let baseline = try Self.peersSegment(rows)
        #expect(baseline.text == "P1 connected (epoch 1), P2 connected (epoch 2)")
        for status in Self.allPermissionStatuses {
            let peers = try Self.peersSegment(rows, localNetwork: status)
            if Self.confirmedOff.contains(status) {
                Self.expectSegment(
                    peers, text: "Peer control unavailable", label: Self.peersOffLabel, severity: .attention
                )
            } else {
                #expect(peers == baseline, "local network \(status)")
            }
        }
    }

    @Test func localNetworkOffSaysPeerControlUnavailableEvenWithNoPeers() throws {
        for status in Self.allPermissionStatuses {
            let peers = try Self.peersSegment([], localNetwork: status)
            if Self.confirmedOff.contains(status) {
                Self.expectSegment(
                    peers, text: "Peer control unavailable", label: Self.peersOffLabel, severity: .attention
                )
            } else {
                Self.expectSegment(peers, text: "No peers", label: "Peers: No peers", severity: .normal)
            }
        }
    }

    @Test func localNetworkOffReplacesTheRowsAndTheirLostItems() throws {
        let gone = try Self.session(epoch: 2)
        let rows = [Self.peer("Remote C", .disconnected(gone), stale: 2)]
        let reachable = try Self.peersSegment(rows)
        #expect(reachable.severity == .error)
        #expect(reachable.lostItems == ["Remote C"])
        let off = try Self.peersSegment(rows, localNetwork: .denied)
        Self.expectSegment(off, text: "Peer control unavailable", label: Self.peersOffLabel, severity: .attention)
    }

    @Test func microphoneAndBluetoothNeverAffectPeers() throws {
        let rows = try Self.syncedPeers(2)
        let baseline = try Self.peersSegment(rows)
        for status in Self.allPermissionStatuses {
            let peers = try Self.segment(.peers) {
                $0.peers = rows
                $0.permissions = Self.permissions(microphone: status, bluetoothMIDI: status)
            }
            #expect(peers == baseline, "status \(status)")
        }
    }

    @Test func peerNamesAreShownVerbatimAndDuplicatesAreNotMerged() throws {
        let first = try Self.session(epoch: 1)
        let second = try Self.session(epoch: 2)
        let name = "  Remote \u{e9} "
        let peers = try Self.peersSegment([Self.peer(name, .connected(first)), Self.peer(name, .resyncing(second))])
        #expect(peers.text == "\(name) connected (epoch 1), \(name) resyncing")
        let lost = try Self.peersSegment([
            Self.peer(name, .disconnected(first)), Self.peer(name, .disconnected(second))
        ])
        #expect(lost.lostItems == [name, name])
    }
}
