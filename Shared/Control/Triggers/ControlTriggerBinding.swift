import Foundation

/// Neutral, opaque identity of what a trigger fires. Triggers never interpret it; consumers (show navigation,
/// action sets, remote control) map IDs to their own commands.
enum ControlTriggerTargetTag: ContractIDTag {}
typealias ControlTriggerTargetID = ContractID<ControlTriggerTargetTag>

/// How press edges become commands.
enum ControlTriggerMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Every press edge is a `press` command; release edges are commands only when the binding asks.
    case momentary
    /// Each press edge flips the output and emits `switchedOn` or `switchedOff`. The switch-off press goes through
    /// the target checks like any press, so a toggle can stay on while its target is not `.live`; the host can
    /// still switch it off with an explicit clear, which needs no target checks.
    case toggle
    /// The first press edge emits `switchedOn`; the output stays on, ignoring presses, until an explicit clear
    /// emits `switchedOff`.
    case latch
}

/// One absolute control (a button, pedal, fader or knob) bound to one trigger target. The control's normalized
/// position is read with hysteresis: it presses when it rises to at least `pressAt` and releases only when it falls
/// to at most `releaseAt`, so values inside the band never chatter. Both thresholds are explicit; nothing assumes
/// a centre. `emitsRelease` (momentary only) makes release edges commands too; `false` is normalised to `nil` when
/// built or decoded, so fields that behave identically compare equal. A decoded record still keeps the original
/// `"emitsRelease":false` spelling to round-trip byte-for-byte, so it (and a detector built from it) may not be `==`
/// to a record built from equal fields.
struct ControlTriggerBindingFields: ControlFields {
    static let knownKeys: Set<String> = [
        "id", "source", "target", "profile", "mode", "pressAt", "releaseAt", "emitsRelease"
    ]
    let id: BindingID
    let source: ControlSourceID
    let target: ControlTriggerTargetID
    /// Must be absolute; relative encoders have no press edge.
    let profile: EncoderProfile
    let mode: ControlTriggerMode
    let pressAt: Double
    let releaseAt: Double
    /// `true` or `nil`; never `false`.
    let emitsRelease: Bool?

    init(id: BindingID, source: ControlSourceID, target: ControlTriggerTargetID, profile: EncoderProfile,
         mode: ControlTriggerMode, pressAt: Double, releaseAt: Double, emitsRelease: Bool? = nil) {
        self.id = id
        self.source = source
        self.target = target
        self.profile = profile
        self.mode = mode
        self.pressAt = pressAt
        self.releaseAt = releaseAt
        self.emitsRelease = emitsRelease == true ? true : nil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(BindingID.self, forKey: .id),
                      source: container.decode(ControlSourceID.self, forKey: .source),
                      target: container.decode(ControlTriggerTargetID.self, forKey: .target),
                      profile: container.decode(EncoderProfile.self, forKey: .profile),
                      mode: container.decode(ControlTriggerMode.self, forKey: .mode),
                      pressAt: container.decode(Double.self, forKey: .pressAt),
                      releaseAt: container.decode(Double.self, forKey: .releaseAt),
                      emitsRelease: container.decodeIfPresent(Bool.self, forKey: .emitsRelease))
    }

    func validate() throws {
        try profile.validate()
        guard !profile.isRelative else {
            throw ControlValidationError.invalid("Trigger bindings require an absolute profile")
        }
        // The ordered comparisons also refuse NaN and infinities.
        guard releaseAt >= 0, releaseAt < pressAt, pressAt <= 1 else {
            throw ControlValidationError.invalid("Trigger thresholds need 0 <= releaseAt < pressAt <= 1")
        }
        guard emitsRelease != true || mode == .momentary else {
            throw ControlValidationError.invalid("Only momentary triggers may emit release commands")
        }
    }
}
typealias ControlTriggerBinding = ControlRecord<ControlTriggerBindingFields>
