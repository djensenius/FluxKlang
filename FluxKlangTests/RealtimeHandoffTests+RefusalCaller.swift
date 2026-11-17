import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private struct RefusalCallerEmptySlot: Error {}

extension RealtimeHandoffTests {
    struct RefusalCalling {
        static func take(_ role: RefusalCaller, sourceLocation: SourceLocation = #_sourceLocation) throws
            -> RefusalCallerToken {
            guard let token = role.take() else {
                Issue.record("refusal caller slot unexpectedly empty", sourceLocation: sourceLocation)
                throw RefusalCallerEmptySlot()
            }
            return token
        }

        static func isEmpty(_ role: RefusalCaller) -> Bool {
            guard let token = role.take() else { return true }
            _ = role.put(token)
            return false
        }

        @Test func repeatedTakeReturnIsExclusive() throws {
            let role = try #require(RefusalCaller.prepare())
            for _ in 0..<100 {
                let token = try Self.take(role)
                #expect(Self.isEmpty(role))
                let status = role.put(token)
                #expect(status == .ok)
            }
            #expect(!Self.isEmpty(role))
        }

        @Test func foreignReturnLeavesAvailableDestinationAndStrandsSource() throws {
            let source = try #require(RefusalCaller.prepare())
            let destination = try #require(RefusalCaller.prepare())
            let foreign = try Self.take(source)
            let status = destination.put(foreign)
            #expect(status == .refused(.notOwner))
            for _ in 0..<10 {
                #expect(Self.isEmpty(source))
                let own = try Self.take(destination)
                #expect(Self.isEmpty(destination))
                let returned = destination.put(own)
                #expect(returned == .ok)
            }
        }

        @Test func foreignReturnLeavesHeldDestinationAndStrandsSource() throws {
            let source = try #require(RefusalCaller.prepare())
            let destination = try #require(RefusalCaller.prepare())
            let own = try Self.take(destination)
            let foreign = try Self.take(source)
            let status = destination.put(foreign)
            #expect(status == .refused(.notOwner))
            #expect(Self.isEmpty(source))
            #expect(Self.isEmpty(destination))
            let returned = destination.put(own)
            #expect(returned == .ok)
            #expect(!Self.isEmpty(destination))
            #expect(Self.isEmpty(source))
        }

        private static func dropToken(_ role: RefusalCaller) throws {
            _ = try take(role)
        }

        private static func orphanToken() throws -> RefusalCallerToken {
            let role = try #require(RefusalCaller.prepare())
            return try take(role)
        }

        @Test func droppedTokenStrandsRoleAndDroppedRoleCannotReissueIdentity() throws {
            let stranded = try #require(RefusalCaller.prepare())
            try Self.dropToken(stranded)
            for _ in 0..<100 {
                #expect(Self.isEmpty(stranded))
                let orphan = try Self.orphanToken()
                let next = try #require(RefusalCaller.prepare())
                let status = next.put(orphan)
                #expect(status == .refused(.notOwner))
                #expect(!Self.isEmpty(next))
            }
            // Exact budget/no-refund evidence additionally uses the labelled reduced-budget fresh process.
        }
    }
}
