import Foundation

extension WingController {
    // MARK: - Stereo pairs

    /// Drives a ganged stereo pair from a single fader `position` (`0...1`) plus
    /// a `balance` trim (`-1` favours left … `0` even … `+1` favours right). The
    /// right node may be `nil`, in which case only the left node is set, so the
    /// same call works for mono strips.
    func setFaderPair(_ left: WingNodeRef, _ right: WingNodeRef?, position: Float, balance: Float = 0) async {
        await setFader(left.kind, left.index, position: position - balance / 2)
        if let right {
            await setFader(right.kind, right.index, position: position + balance / 2)
        }
    }

    /// Links the mute of a stereo pair (or just the left node when `right` is nil).
    func setMutePair(_ left: WingNodeRef, _ right: WingNodeRef?, muted: Bool) async {
        await setMute(left.kind, left.index, muted: muted)
        if let right {
            await setMute(right.kind, right.index, muted: muted)
        }
    }

    /// Hard-pans a stereo pair fully left and right so it images correctly.
    func hardPanPair(_ left: WingNodeRef, _ right: WingNodeRef?) async {
        await setPan(left.kind, left.index, pan: -1)
        if let right {
            await setPan(right.kind, right.index, pan: 1)
        }
    }

    /// Length of the ` L`/` R` suffix appended to each node of a stereo pair.
    private static let stereoSuffixLength = 2

    /// Renames a strip on the console. For a stereo pair the two nodes get the
    /// shared name with ` L`/` R` suffixes; a mono strip gets the name as-is. The
    /// base name is clamped to leave room for the suffix so both nodes stay
    /// distinct within ``maxNameLength``.
    func setNamePair(_ left: WingNodeRef, _ right: WingNodeRef?, to name: String) async {
        if let right {
            let base = Self.sanitizeName(name, maxLength: Self.maxNameLength - Self.stereoSuffixLength)
            await setName(left.kind, left.index, to: base + " L")
            await setName(right.kind, right.index, to: base + " R")
        } else {
            await setName(left.kind, left.index, to: name)
        }
    }
}
