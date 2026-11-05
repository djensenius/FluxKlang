//
//  OpenSoundControl+AddressGrammar.swift
//  FluxKlang
//
//  Validates addresses and compiles patterns. Addresses are `/`-separated,
//  non-empty parts of printable ASCII without space or `#`. Literal addresses
//  also refuse `* ? [ ] { } ,`. Groups never nest or span a `/`.
//

extension OpenSoundControl {
    struct AddressGrammar {
        static let slash = UInt8(ascii: "/")
        private static let specials = Set("/*?[]{},".utf8)

        private let bytes: [UInt8]
        private let allowWildcards: Bool
        private var index = 0
        private var literal: [UInt8] = []
        private var tokens: [PatternToken] = []
        private var complexity = 0

        private init(bytes: [UInt8], allowWildcards: Bool) {
            self.bytes = bytes
            self.allowWildcards = allowWildcards
        }

        static func parse(
            _ bytes: [UInt8], allowWildcards: Bool, limits: Limits
        ) throws(CodecError) -> (tokens: [PatternToken], complexity: Int) {
            guard bytes.count <= limits.maximumStringBytes else {
                throw .invalidAddress(.tooLong(byteCount: bytes.count, limit: limits.maximumStringBytes))
            }
            guard bytes.first == slash else { throw .invalidAddress(.missingLeadingSlash) }
            var grammar = AddressGrammar(bytes: bytes, allowWildcards: allowWildcards)
            while grammar.index < bytes.count { try grammar.step() }
            grammar.flushLiteral()
            let complexityLimit = limits.maximumPatternComplexity
            guard grammar.complexity <= complexityLimit else {
                throw .invalidAddress(.tooComplex(complexity: grammar.complexity, limit: complexityLimit))
            }
            return (grammar.tokens, grammar.complexity)
        }

        private mutating func step() throws(CodecError) {
            let byte = bytes[index]
            try Self.requirePrintable(byte)
            guard Self.specials.contains(byte) else {
                literal.append(byte)
                index += 1
                return
            }
            guard allowWildcards || byte == Self.slash else { throw .invalidAddress(.wildcardInAddress(byte)) }
            switch byte {
            case Self.slash:
                guard index + 1 < bytes.count, bytes[index + 1] != Self.slash else { throw .invalidAddress(.emptyPart) }
                literal.append(byte)
                index += 1
            case UInt8(ascii: "*"), UInt8(ascii: "?"):
                appendToken(byte == UInt8(ascii: "*") ? .anySequence : .anyCharacter, complexity: 1)
                index += 1
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                try appendGroup(isBracket: byte == UInt8(ascii: "["))
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                throw .invalidAddress(byte == UInt8(ascii: "]") ? .unbalancedBracket : .unbalancedBrace)
            default:
                throw .invalidAddress(.invalidCharacter(byte))
            }
        }

        private mutating func flushLiteral() {
            if !literal.isEmpty { tokens.append(.literal(literal)) }
            literal = []
        }

        private mutating func appendToken(_ token: PatternToken, complexity weight: Int) {
            flushLiteral()
            tokens.append(token)
            complexity += weight
        }

        private mutating func appendGroup(isBracket: Bool) throws(CodecError) {
            let body = try groupBody(isBracket: isBracket)
            if isBracket {
                appendToken(.set(try Self.byteSet(body)), complexity: 1)
            } else {
                guard !body.isEmpty else { throw .invalidAddress(.emptyGroup) }
                let alternatives = body.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false)
                appendToken(.alternatives(alternatives.map(Array.init)), complexity: alternatives.count)
            }
            index += body.count + 2
        }

        /// Bytes between the opener at `index` and its closer.
        private func groupBody(isBracket: Bool) throws(CodecError) -> ArraySlice<UInt8> {
            let close = isBracket ? UInt8(ascii: "]") : UInt8(ascii: "}")
            let unbalanced: AddressRefusal = isBracket ? .unbalancedBracket : .unbalancedBrace
            let start = index + 1
            for position in start..<bytes.count {
                let byte = bytes[position]
                if byte == close { return bytes[start..<position] }
                try Self.requirePrintable(byte)
                switch byte {
                case Self.slash, UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"):
                    throw .invalidAddress(unbalanced)
                case UInt8(ascii: "*"), UInt8(ascii: "?"):
                    throw .invalidAddress(.invalidCharacter(byte))
                case UInt8(ascii: ",") where isBracket:
                    throw .invalidAddress(.invalidCharacter(byte))
                default:
                    continue
                }
            }
            throw .invalidAddress(unbalanced)
        }

        private static func requirePrintable(_ byte: UInt8) throws(CodecError) {
            guard byte > 0x20, byte < 0x7F, byte != UInt8(ascii: "#") else {
                throw .invalidAddress(.invalidCharacter(byte))
            }
        }

        /// `[!a-z]`: a leading `!` negates, `-` between two characters is a
        /// range, and a leading or trailing `-` is literal.
        private static func byteSet(_ body: ArraySlice<UInt8>) throws(CodecError) -> ByteSet {
            var members = Array(body)
            let negated = members.first == UInt8(ascii: "!")
            if negated { members.removeFirst() }
            guard !members.isEmpty else { throw .invalidAddress(.emptyGroup) }
            var ranges: [ClosedRange<UInt8>] = []
            var position = 0
            while position < members.count {
                if position + 2 < members.count, members[position + 1] == UInt8(ascii: "-") {
                    let low = members[position], high = members[position + 2]
                    guard low <= high else { throw .invalidAddress(.invalidRange) }
                    ranges.append(low...high)
                    position += 3
                } else {
                    ranges.append(members[position]...members[position])
                    position += 1
                }
            }
            return ByteSet(ranges: ranges, negated: negated)
        }
    }
}
