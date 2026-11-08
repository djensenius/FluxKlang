extension MIDICapabilityResolver {
    /// Runs the nine refusal checks in the documented order and returns the sorted inputs. The two count checks
    /// come first and look only at counts.
    static func validatedInputs(_ facts: MIDICapabilityFacts) throws(MIDICapabilityRefusal) -> Inputs {
        let suppliedBlocks = facts.functionBlocks.count
        guard suppliedBlocks <= MIDICapabilityLimits.maximumFunctionBlocks else {
            throw .tooManyFunctionBlocks(count: suppliedBlocks)
        }
        let advertised = advertisedProfiles(facts.ciAnswer)
        guard advertised.count <= MIDICapabilityLimits.maximumProfiles else {
            throw .tooManyProfiles(count: advertised.count)
        }
        try validateEndpoint(facts.endpoint, supplied: suppliedBlocks)
        let blocks = sortedBlocks(facts.functionBlocks)
        try validateBlocks(blocks)
        let profiles = advertised.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        if let repeated = repeatedProfile(profiles) { throw .duplicateProfile(repeated) }
        return Inputs(
            endpoint: facts.endpoint, blocks: blocks, profiles: profiles, answered: isAnswered(facts.ciAnswer),
            profileConfigurationAnnounced: announcesProfiles(facts.ciAnswer))
    }

    private static func advertisedProfiles(_ answer: MIDICapabilityCIAnswer) -> [MIDICapabilityProfileID] {
        switch answer {
        case .missing: return []
        case .answered(_, let profiles): return profiles
        }
    }

    private static func isAnswered(_ answer: MIDICapabilityCIAnswer) -> Bool {
        switch answer {
        case .missing: return false
        case .answered: return true
        }
    }

    private static func announcesProfiles(_ answer: MIDICapabilityCIAnswer) -> Bool {
        switch answer {
        case .missing:
            return false
        case .answered(let info, _):
            return info.capabilityCategory & MIDICapabilityCIAnswer.profileConfigurationBit != 0
        }
    }

    private static func validateEndpoint(
        _ endpoint: UMPStreamEndpointInfo?, supplied: Int
    ) throws(MIDICapabilityRefusal) {
        guard let endpoint else {
            if supplied > 0 { throw .functionBlocksWithoutEndpoint(count: supplied) }
            return
        }
        do throws(UMPStreamRefusal) {
            try endpoint.validate()
        } catch {
            throw .endpointInvalid(error)
        }
        guard endpoint.functionBlockCount == supplied else {
            throw .functionBlockCountMismatch(declared: endpoint.functionBlockCount, supplied: supplied)
        }
    }

    private static func validateBlocks(_ blocks: [UMPStreamFunctionBlockInfo]) throws(MIDICapabilityRefusal) {
        for block in blocks {
            do throws(UMPStreamRefusal) {
                try block.validate()
            } catch {
                throw .functionBlockInvalid(index: block.index, error)
            }
        }
        if let repeated = repeatedIndex(blocks) { throw .duplicateFunctionBlockIndex(repeated) }
        if let pair = overlappingPair(blocks) {
            throw .overlappingFunctionBlockGroups(first: pair.first, second: pair.second)
        }
    }

    private static func sortedBlocks(_ blocks: [UMPStreamFunctionBlockInfo]) -> [UMPStreamFunctionBlockInfo] {
        blocks.sorted { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }
    }

    private static func sortKey(_ block: UMPStreamFunctionBlockInfo) -> [Int] {
        [
            block.index, block.firstGroup, block.groupCount, block.isActive ? 1 : 0, Int(block.midiCIVersion),
            Int(block.maximumSysEx8Streams), Int(block.uiHint.rawValue), Int(block.midi1Mode.rawValue),
            Int(block.direction.rawValue)
        ]
    }

    private static func repeatedIndex(_ blocks: [UMPStreamFunctionBlockInfo]) -> Int? {
        for (earlier, later) in zip(blocks, blocks.dropFirst()) where earlier.index == later.index {
            return earlier.index
        }
        return nil
    }

    private static func repeatedProfile(_ profiles: [MIDICapabilityProfileID]) -> MIDICapabilityProfileID? {
        for (earlier, later) in zip(profiles, profiles.dropFirst()) where earlier == later {
            return earlier
        }
        return nil
    }

    /// The first pair, first index ascending then second index ascending, whose group ranges share a group.
    private static func overlappingPair(_ blocks: [UMPStreamFunctionBlockInfo]) -> (first: Int, second: Int)? {
        for earlierPosition in blocks.indices {
            let earlier = blocks[earlierPosition]
            for later in blocks[(earlierPosition + 1)...] where sharesGroup(earlier, later) {
                return (first: earlier.index, second: later.index)
            }
        }
        return nil
    }

    private static func sharesGroup(_ lhs: UMPStreamFunctionBlockInfo, _ rhs: UMPStreamFunctionBlockInfo) -> Bool {
        let left = lhs.firstGroup..<(lhs.firstGroup + lhs.groupCount)
        let right = rhs.firstGroup..<(rhs.firstGroup + rhs.groupCount)
        return left.lowerBound < right.upperBound && right.lowerBound < left.upperBound
    }
}
