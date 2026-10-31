//
//  LaunchControlXLAppModel.swift
//  FluxKlang
//

import Foundation

extension AppModel {
    /// Startup step from `loadStores()`: routes actions here, then loads and restarts the input.
    func loadLaunchControlXL() async {
        launchControlXL.setActionHandler { [weak self] action in
            await self?.handleLaunchControlXL(action)
        }
        await launchControlXL.load()
    }

    func handleLaunchControlXL(_ action: LaunchControlXLAction) async {
        switch action {
        case .moveBank(let delta):
            launchControlXL.moveBank(delta, stripCount: faderLayout.layout.strips.count)
        case .select(let slot):
            guard let strip = launchControlStrip(slot: slot) else { return }
            selectStrip(strip)
        case .fader(let slot, let value):
            guard wing.connection.isConnected,
                  let strip = launchControlStrip(slot: slot) else { return }
            await wing.setFaderPair(
                strip.node,
                strip.rightNode,
                position: value,
                balance: launchControlLiveBalance(for: strip)
            )
        case .panOrBalance(let slot, let value):
            guard wing.connection.isConnected,
                  let strip = launchControlStrip(slot: slot) else { return }
            if strip.isStereo {
                await wing.setFaderPair(
                    strip.node,
                    strip.rightNode,
                    position: launchControlLiveCenter(for: strip),
                    balance: value
                )
            } else {
                await wing.setPan(strip.node.kind, strip.node.index, pan: value)
            }
        case .toggleMute(let slot):
            guard wing.connection.isConnected,
                  let strip = launchControlStrip(slot: slot) else { return }
            await wing.setMutePair(
                strip.node,
                strip.rightNode,
                muted: !(wing.isMuted(strip.node.kind, strip.node.index) ?? false)
            )
        }
    }

    private func launchControlStrip(slot: Int) -> FaderStrip? {
        let index = launchControlXL.stripIndex(for: slot)
        guard faderLayout.layout.strips.indices.contains(index) else { return nil }
        return faderLayout.layout.strips[index]
    }

    private func launchControlLiveCenter(for strip: FaderStrip) -> Float {
        let left = wing.faderPosition(strip.node.kind, strip.node.index) ?? FaderMath.unityPosition
        guard let rightNode = strip.rightNode else { return left }
        let right = wing.faderPosition(rightNode.kind, rightNode.index) ?? left
        return (left + right) / 2
    }

    private func launchControlLiveBalance(for strip: FaderStrip) -> Float {
        guard let rightNode = strip.rightNode else { return 0 }
        let left = wing.faderPosition(strip.node.kind, strip.node.index) ?? FaderMath.unityPosition
        let right = wing.faderPosition(rightNode.kind, rightNode.index) ?? left
        return min(max(right - left, -1), 1)
    }
}
