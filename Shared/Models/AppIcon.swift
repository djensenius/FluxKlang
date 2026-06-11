//
//  AppIcon.swift
//  FluxKlang
//
//  The selectable app icons and a small manager that applies the user's choice.
//  iOS switches between the primary and alternate icons; macOS has no alternate-
//  icon API, so it swaps the Dock icon at runtime and re-applies the saved choice
//  on launch (the Dock override does not persist across launches).
//

import Foundation
import Observation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A user-selectable app icon. `waveform` is the primary (default) icon, shipped
/// as the layered Icon Composer asset; the others are alternates.
enum AppIconOption: String, CaseIterable, Identifiable, Sendable {
    case waveform
    case wave
    case fader

    var id: String { rawValue }

    /// The catalog alternate-icon name, or `nil` for the primary icon.
    var alternateName: String? {
        switch self {
        case .waveform: return nil
        case .wave: return "AppIconWave"
        case .fader: return "AppIconFader"
        }
    }

    /// Asset name of the preview thumbnail (also used as the macOS Dock image).
    var thumbnail: String {
        switch self {
        case .waveform: return "IconThumbWaveform"
        case .wave: return "IconThumbWave"
        case .fader: return "IconThumbFader"
        }
    }

    var label: String {
        switch self {
        case .waveform: return "Waveform"
        case .wave: return "Wave"
        case .fader: return "Fader"
        }
    }

    var detail: String {
        switch self {
        case .waveform: return "Three-stroke signal flow"
        case .wave: return "Single flowing brushstroke"
        case .fader: return "Inked channel fader"
        }
    }
}

/// Applies and persists the chosen app icon across platforms.
@MainActor
@Observable
final class AppIconManager {
    private let storageKey = "fluxklang.appIcon"

    /// The currently selected icon.
    private(set) var selected: AppIconOption

    init() {
        let stored = UserDefaults.standard.string(forKey: storageKey)
        selected = stored.flatMap(AppIconOption.init(rawValue:)) ?? .waveform
        #if os(macOS)
        applyToDock(selected)
        #endif
    }

    /// Whether the running platform/device allows switching icons.
    var canChangeIcon: Bool {
        #if os(iOS)
        return UIApplication.shared.supportsAlternateIcons
        #else
        return true
        #endif
    }

    /// Selects an icon and applies it to the system, persisting the choice only
    /// once the change actually takes effect. On iOS the system reports success
    /// asynchronously, so cancelling or a failure leaves the prior icon intact.
    func select(_ option: AppIconOption) {
        guard option != selected else { return }
        #if os(iOS)
        guard UIApplication.shared.supportsAlternateIcons else { return }
        UIApplication.shared.setAlternateIconName(option.alternateName) { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor in self?.commit(option) }
        }
        #elseif os(macOS)
        applyToDock(option)
        commit(option)
        #endif
    }

    /// Records the selection and persists it. Called only after the icon change
    /// has succeeded.
    private func commit(_ option: AppIconOption) {
        selected = option
        UserDefaults.standard.set(option.rawValue, forKey: storageKey)
    }

    #if os(macOS)
    private func applyToDock(_ option: AppIconOption) {
        // The primary icon is the bundle's layered icon; clearing the override
        // restores it. Alternates swap in the matching thumbnail image.
        if option == .waveform {
            NSApplication.shared.applicationIconImage = nil
        } else {
            NSApplication.shared.applicationIconImage = NSImage(named: option.thumbnail)
        }
    }
    #endif
}
