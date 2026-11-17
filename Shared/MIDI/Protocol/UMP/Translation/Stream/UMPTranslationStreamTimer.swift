/// The one-shot deadline timer of `UMPTranslationStreamDriver`. The driver arms it for the earliest held CC 6 of all
/// its streams; `fire` is called once when `atNanoseconds` (the clock's time base) is reached, and must never run on
/// the audio render thread.
protocol UMPTranslationStreamTimer: Sendable {
    /// Arms the timer; a new arming replaces the previous one.
    func arm(atNanoseconds: UInt64, fire: @escaping @Sendable () -> Void)
    /// Cancels the armed deadline, if any. Calling it again, or with nothing armed, does nothing.
    func cancel()
}
