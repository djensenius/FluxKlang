extension AppModel {
    /// Pushes a placed voice's surround bus sends to the WING live, used while
    /// dragging it around the spatial field.
    func applyVoicePlacement(_ placed: PlacedVoice) async {
        guard let source = placed.voice.spatialSource(position: placed.position, width: placed.width) else { return }
        await wing.apply(SpatialRouting.settings(for: source, speakers: spatial.array.speakers))
    }

    /// Re-applies every placed voice of the active environment. Used by the
    /// spatial screen's "Apply" action.
    func applyAllPlacements() async {
        await wing.apply(environmentSpatialSettings())
    }

    /// Sets a stereo speaker pair's level (normalised), with an optional balance
    /// offset (`-1...1`) trimming left versus right.
    func setSpeakerPair(_ pair: SpeakerPair, position: Float, balance: Float = 0) async {
        guard let left = spatial.array.speaker(pair.left)?.node else { return }
        let right = spatial.array.speaker(pair.right)?.node
        await wing.setFaderPair(left, right, position: position, balance: balance)
    }

    /// Mutes or unmutes both speakers in a pair.
    func setSpeakerPairMuted(_ pair: SpeakerPair, muted: Bool) async {
        guard let left = spatial.array.speaker(pair.left)?.node else { return }
        let right = spatial.array.speaker(pair.right)?.node
        await wing.setMutePair(left, right, muted: muted)
    }
}
