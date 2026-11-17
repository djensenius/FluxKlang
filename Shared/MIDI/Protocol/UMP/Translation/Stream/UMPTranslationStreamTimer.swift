/// The one-shot deadline timer of `UMPTranslationStreamDriver`. The driver arms it for the earliest held CC 6 of all
/// its streams; `fire` is run once when `atNanoseconds` (the clock's time base) is reached, at once if it already
/// has been. The timer runs `fire` off the audio render thread (for example in a `Task`), never on it. A callback
/// already queued may still run after `cancel()` or a new arming; the driver tolerates that, so `cancel()` need not
/// be synchronous.
protocol UMPTranslationStreamTimer: Sendable {
    /// Arms the timer; a new arming replaces the previous one.
    func arm(atNanoseconds: UInt64, fire: @escaping @Sendable () async -> Void)
    /// Cancels the armed deadline, if any. Calling it again, or with nothing armed, does nothing.
    func cancel()
}
