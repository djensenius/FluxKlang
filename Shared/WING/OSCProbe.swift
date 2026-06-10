//
//  OSCProbe.swift
//  FluxKlang
//
//  Temporary anchor that links the SwiftOSC package into the build. This is
//  replaced by the real OSC transport / WingController in the wing-core phase.
//

import Foundation
import SwiftOSC

enum OSCProbe {
    static let bootstrapAddress = "/ping"
}
