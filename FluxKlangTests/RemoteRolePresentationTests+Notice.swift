import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = RemoteRolePresentationFixture

/// The discarded-changes notice of the remote role presentation (#96 REM1): the document's sentence while the
/// values match, a shorter one while they do not, and none for an absent or empty report.
extension RemoteRolePresentationTests {
    @Test func aConnectedNoticeSaysTheValuesMatchTheHost() throws {
        let role = try Fixture.role()
        let two = try Fixture.make(role: role, phase: Fixture.synced(), discarded: Fixture.report(discarding: 2))
        #expect(two.notice == "2 queued changes discarded. Values now match Host A.")
        let one = try Fixture.make(role: role, phase: Fixture.synced(), discarded: Fixture.report(discarding: 1))
        #expect(one.notice == "1 queued change discarded. Values now match Host A.")
    }

    @Test func aNoticeBeforeTheValuesMatchMakesNoSuchClaim() throws {
        let role = try Fixture.role()
        let session = Fixture.session()
        let resyncing = PeerReconnectState.Phase.resyncing(session)
        let two = try Fixture.make(role: role, phase: resyncing, discarded: Fixture.report(discarding: 2))
        #expect(two.notice == "2 queued changes discarded.")
        let one = try Fixture.make(role: role, phase: resyncing, discarded: Fixture.report(discarding: 1))
        #expect(one.notice == "1 queued change discarded.")
        let disconnected = try Fixture.make(
            role: role, phase: .disconnected(session), discarded: Fixture.report(discarding: 2)
        )
        #expect(disconnected.notice == "2 queued changes discarded.")
    }

    @Test func noReportOrAnEmptyReportHasNoNotice() throws {
        let role = try Fixture.role()
        #expect(try Fixture.make(role: role, phase: Fixture.synced()).notice == nil)
        let empty = try Fixture.make(role: role, phase: Fixture.synced(), discarded: Fixture.report(discarding: 0))
        #expect(empty.notice == nil)
    }

    @Test func anEmptyReportOfALostHostHasNoNotice() throws {
        let lost = try Fixture.make(
            role: Fixture.role(.hostLost), phase: Fixture.synced(), discarded: Fixture.report(discarding: 0)
        )
        #expect(lost.notice == nil)
        let withChanges = try Fixture.make(
            role: Fixture.role(.hostLost), phase: Fixture.synced(), discarded: Fixture.report(discarding: 2)
        )
        // A lost host is shown disconnected, so the notice makes no claim that the values match.
        #expect(withChanges.notice == "2 queued changes discarded.")
    }

    @Test func anObserverTrustsTheReportItIsGivenAndStillNeverEnablesInput() throws {
        // An observer cannot enqueue, so such a report is not expected; the value shows it as given.
        let observer = try Fixture.role(grant: .observer)
        let value = try Fixture.make(role: observer, phase: Fixture.synced(), discarded: Fixture.report(discarding: 2))
        #expect(value.notice == "2 queued changes discarded. Values now match Host A.")
        #expect(!value.inputsEnabled)
    }

    @Test func aMissingNameShowsTheHostIDInTheNotice() throws {
        let value = try Fixture.make(
            role: Fixture.role(), phase: Fixture.synced(), name: nil, discarded: Fixture.report(discarding: 2)
        )
        #expect(value.notice == "2 queued changes discarded. Values now match host.reconnect.")
    }
}
