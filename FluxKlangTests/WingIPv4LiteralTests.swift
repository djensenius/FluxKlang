import Testing
@testable import FluxKlang

struct WingIPv4LiteralTests {
    @Test(arguments: ["192.0.2.10", "127.0.0.1", "0.0.0.0", "255.255.255.255"])
    func numericIPv4NeedsNoResolution(_ host: String) {
        #expect(WingIPv4Literal.canonicalized(host) == host)
    }

    @Test(arguments: [
        "", "must-not-resolve.invalid", "256.0.0.1", "1.2.3",
        "1.2.3.4\u{0}ignored", " 192.0.2.10", "192.0.2.10\n", "192.0.2.10:2223"
    ])
    func nonLiteralsCannotBeTruncatedOrResolved(_ host: String) {
        #expect(WingIPv4Literal.canonicalized(host) == nil)
    }
}
