import Foundation

/// A lexical, case-sensitive relative name, not a filesystem confinement or alias proof.
/// The root is implicit and cannot be represented by an admitted path.
struct ProjectPackagePath: Sendable, Equatable {
    let value: String
    let parent: String?
    let depth: Int
    let utf8ByteCount: Int

    init(_ path: String, limits: ProjectPackageLimits) throws(ProjectPackageError) {
        let bounds = try Self.scanBounds(path, limits: limits)

        // Scalar-level separators also handle a slash followed by a combining mark.
        // Unicode control scalars (Cc) are forbidden; other NFC Unicode names are allowed.
        var previous: Unicode.Scalar?
        for scalar in path.unicodeScalars {
            guard scalar != "\\", scalar != ":", scalar != "%",
                  scalar.properties.generalCategory != .control else { throw .invalidPath }
            if scalar == "/" {
                guard let previous, previous != "/", previous != ".", previous != " " else {
                    throw .invalidPath
                }
            }
            previous = scalar
        }
        guard let previous, previous != "/", previous != ".", previous != " " else { throw .invalidPath }

        // String equality is canonically equivalent; it cannot detect non-NFC input bytes.
        guard path.utf8.elementsEqual(path.precomposedStringWithCanonicalMapping.utf8) else {
            throw .nonNFCPath
        }
        value = path
        if let separator = path.unicodeScalars.lastIndex(of: "/") {
            parent = String(path.unicodeScalars[..<separator])
        } else {
            parent = nil
        }
        depth = bounds.depth
        utf8ByteCount = bounds.bytes
    }

    private static func scanBounds(
        _ path: String, limits: ProjectPackageLimits
    ) throws(ProjectPackageError) -> (bytes: Int, depth: Int) {
        // Bound work before splitting components, copying prefixes, or allocating NFC text.
        // Check before incrementing so even Int.max policies cannot overflow these counters.
        var byteCount = 0
        var componentCount = 1
        for byte in path.utf8 {
            guard byteCount < limits.maxPathUTF8Bytes else { throw .pathTooLong }
            byteCount += 1
            if byte == 47 {
                guard componentCount < limits.maxDepth else { throw .pathTooDeep }
                componentCount += 1
            }
        }
        return (byteCount, componentCount)
    }
}
