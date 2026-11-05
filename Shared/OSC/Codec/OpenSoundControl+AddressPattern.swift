//
//  OpenSoundControl+AddressPattern.swift
//  FluxKlang
//
//  OSC 1.0 addresses and address patterns. Patterns support `*`, `?`, `[...]`
//  (ranges and `!` negation) and `{a,b}`; wildcards never match `/`. Matching
//  is a reachability sweep over address offsets, so work is bounded by
//  tokens x address bytes x pattern bytes with no backtracking.
//

extension OpenSoundControl {
    /// A literal method or container address such as `/mixer/ch/1/fader`.
    struct Address: Sendable, Hashable, CustomStringConvertible {
        let bytes: [UInt8]
        let stringValue: String

        init(_ string: String, limits: Limits = .standard) throws(CodecError) {
            let bytes = Array(string.utf8)
            _ = try AddressGrammar.parse(bytes, allowWildcards: false, limits: limits)
            self.bytes = bytes
            stringValue = string
        }

        var description: String { stringValue }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.bytes == rhs.bytes }
        func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
    }

    /// A message's address pattern; a literal address is a pattern without wildcards.
    struct AddressPattern: Sendable, Hashable, CustomStringConvertible {
        let bytes: [UInt8]
        let stringValue: String
        let complexity: Int
        private let tokens: [PatternToken]

        init(_ string: String, limits: Limits = .standard) throws(CodecError) {
            try self.init(bytes: Array(string.utf8), limits: limits)
        }

        init(bytes: [UInt8], limits: Limits) throws(CodecError) {
            let parsed = try AddressGrammar.parse(bytes, allowWildcards: true, limits: limits)
            self.bytes = bytes
            // Validation admits printable ASCII only, so each byte is one scalar.
            stringValue = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
            tokens = parsed.tokens
            complexity = parsed.complexity
        }

        var description: String { stringValue }
        var hasWildcards: Bool { complexity > 0 }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.bytes == rhs.bytes }
        func hash(into hasher: inout Hasher) { hasher.combine(bytes) }

        /// Whether this pattern matches the whole of `address`.
        func matches(_ address: Address) -> Bool {
            var reachable = [Bool](repeating: false, count: address.bytes.count + 1)
            reachable[0] = true
            for token in tokens {
                let next = token.advance(reachable, over: address.bytes)
                guard next.contains(true) else { return false }
                reachable = next
            }
            return reachable[address.bytes.count]
        }
    }

    struct ByteSet: Sendable {
        var ranges: [ClosedRange<UInt8>]
        var negated: Bool

        func contains(_ byte: UInt8) -> Bool {
            ranges.contains { $0.contains(byte) } != negated
        }
    }

    enum PatternToken: Sendable {
        case literal([UInt8])
        case anyCharacter
        case anySequence
        case set(ByteSet)
        case alternatives([[UInt8]])

        /// Offsets reachable after this token, given offsets reachable before it.
        func advance(_ reachable: [Bool], over target: [UInt8]) -> [Bool] {
            switch self {
            case .literal(let literal): Self.advance(reachable, over: target, literals: [literal])
            case .alternatives(let literals): Self.advance(reachable, over: target, literals: literals)
            case .anyCharacter: Self.advance(reachable, over: target) { _ in true }
            case .set(let set): Self.advance(reachable, over: target, where: set.contains)
            case .anySequence: Self.advanceSequence(reachable, over: target)
            }
        }

        private static func advance(_ reachable: [Bool], over target: [UInt8], literals: [[UInt8]]) -> [Bool] {
            var next = [Bool](repeating: false, count: reachable.count)
            for start in reachable.indices where reachable[start] {
                for literal in literals where literal.count <= target.count - start
                    && target[start..<(start + literal.count)].elementsEqual(literal) {
                    next[start + literal.count] = true
                }
            }
            return next
        }

        private static func advance(
            _ reachable: [Bool], over target: [UInt8], where accepts: (UInt8) -> Bool
        ) -> [Bool] {
            var next = [Bool](repeating: false, count: reachable.count)
            for start in target.indices where reachable[start] && target[start] != AddressGrammar.slash
                && accepts(target[start]) {
                next[start + 1] = true
            }
            return next
        }

        /// `*`: any run of non-`/` bytes, including none.
        private static func advanceSequence(_ reachable: [Bool], over target: [UInt8]) -> [Bool] {
            var next = [Bool](repeating: false, count: reachable.count)
            var active = false
            for offset in reachable.indices {
                if reachable[offset] { active = true }
                if active { next[offset] = true }
                if offset < target.count, target[offset] == AddressGrammar.slash { active = false }
            }
            return next
        }
    }
}
