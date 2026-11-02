import Darwin
import Foundation

enum WingIPv4Literal {
    static func canonicalized(_ host: String) -> String? {
        guard !host.utf8.contains(0) else { return nil }
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        let capacity = Int(INET_ADDRSTRLEN)
        var buffer = [CChar](repeating: 0, count: capacity)
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(capacity)) != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }
}
