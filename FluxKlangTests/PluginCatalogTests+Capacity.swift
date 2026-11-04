import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginCatalogTests {
    @Test func fullCatalogsWithQuarantineAcceptCompleteReportsWithinTheOrdinaryCap() throws {
        var catalog = try Self.fullCatalog()
        let bare = try Self.evidence(count: 1)[0]
        _ = try catalog.recordQuarantine([bare])
        let installed = try Self.report(count: PluginCatalogLimits.entries).entries
        let failed = PluginScanEntry(identity: bare.identity, outcome: .failed(.validationFailed))
        let complete = PluginScanReport(entries: installed + [failed])
        #expect(complete.entries.count == PluginCatalogLimits.entries + 1)

        let change = try catalog.apply(complete, for: catalog.request(depth: .metadataOnly))
        #expect(change.changed == [bare.identity.id] && change.deferred == 0)
        #expect(catalog.entries[bare.identity.id]?.presence == .failed(.validationFailed))

        let described = try PluginScanReport(entries: installed + [Self.described(bare.identity)])
        let capped = try catalog.apply(described, for: catalog.request(depth: .metadataOnly))
        #expect(capped.deferred == 1 && catalog.entries[bare.identity.id]?.isBare == true)
        #expect(catalog.entries.values.count { !$0.isBare } == PluginCatalogLimits.entries)
    }

    @Test func replacingAComponentAtTheCapMarksItMissingAndDefersTheNewcomer() throws {
        var catalog = try Self.fullCatalog()
        let installed = try Self.report(count: PluginCatalogLimits.entries).entries
        let removed = installed[0].identity.id
        let newcomer = try Self.identity("New!")
        let replacement = try PluginScanReport(entries: Array(installed.dropFirst()) + [Self.described(newcomer)])

        let first = try catalog.apply(replacement, for: catalog.request(depth: .metadataOnly))
        #expect(first.changed == [removed] && first.deferred == 1)
        #expect(catalog.entries[removed]?.presence == .missing && catalog.entries[newcomer.id] == nil)
        #expect(catalog.entries.count == PluginCatalogLimits.entries)

        _ = try catalog.forget(removed)
        let second = try catalog.apply(replacement, for: catalog.request(depth: .metadataOnly))
        #expect(second.changed == [newcomer.id] && second.deferred == 0)
        #expect(catalog.entries[newcomer.id]?.presence == .installed)
        #expect(catalog.entries.count == PluginCatalogLimits.entries)
    }

    @Test func deferralAtTheCapDependsOnIdentityNotScanOrder() throws {
        var start = PluginCatalog()
        let installed = try Self.report(count: PluginCatalogLimits.entries - 2).entries
        _ = try start.apply(PluginScanReport(entries: installed), for: start.request(depth: .metadataOnly))
        let newcomers = try ["Nw4", "Nw1", "Nw3", "Nw2"].map { try Self.described(Self.identity($0 + "!")) }
        let ids = newcomers.map(\.identity.id).sorted()

        var forward = start
        var reversed = start
        let first = try forward.apply(
            PluginScanReport(entries: installed + newcomers), for: forward.request(depth: .metadataOnly)
        )
        let second = try reversed.apply(
            PluginScanReport(entries: (installed + newcomers).reversed()), for: reversed.request(depth: .metadataOnly)
        )
        #expect(forward == reversed && first == second && first.deferred == 2)
        #expect(first.changed == Array(ids.prefix(2)))
        #expect(forward.entries[ids[2]] == nil && forward.entries[ids[3]] == nil)
        #expect(forward.entries.count == PluginCatalogLimits.entries)
    }

    @Test func aCrashAtTheCapUsesHeadroomWhileTheNewcomerIsDeferred() throws {
        var catalog = try Self.fullCatalog()
        let installed = try Self.report(count: PluginCatalogLimits.entries).entries
        let (newcomer, crasher) = try (Self.identity("New!"), Self.identity("Bang"))
        let report = try PluginScanReport(
            entries: installed + [Self.described(newcomer), PluginScanEntry(identity: crasher, outcome: .probeCrashed)]
        )

        let change = try catalog.apply(report, for: catalog.request(depth: .instantiatingProbe))
        #expect(change.changed == [crasher.id] && change.deferred == 1)
        #expect(catalog.entries[newcomer.id] == nil && catalog.quarantined == [crasher.id])
        #expect(catalog.entries[crasher.id]?.isBare == true)
        #expect(catalog.entries.values.count { !$0.isBare } == PluginCatalogLimits.entries)
        #expect(catalog.entries.count == PluginCatalogLimits.entries + 1)
        #expect(catalog.entries.count <= PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom)
    }
}
