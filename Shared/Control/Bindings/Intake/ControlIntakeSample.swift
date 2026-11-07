/// One decoded controller input: where it came from (`key`), the raw value, the message width and the decoded
/// `ControlInput`. Only `MIDIControlIntake` constructs samples in production; the initializer is internal because the
/// intake files are split across files, so tests may build samples to compare. Not `Codable`.
struct ControlIntakeSample: Equatable, Sendable {
    let key: ControlSourceKey
    let raw: Int
    let width: EncoderBitWidth
    let input: ControlInput

    /// The persisted form of the source.
    var source: ControlSourceID { key.sourceID }
}
