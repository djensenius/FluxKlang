//
//  MIDICIPropertyHeaderRefusal.swift
//  FluxKlang
//
//  Why `MIDICIPropertyHeader.parse(_:)` refused header data (#83, slice M83-PXH1, issue #820). A separate type from
//  `MIDICIRefusal`, which covers the message envelope. Nothing calls it yet.
//

/// The cases are listed in the order `MIDICIPropertyHeader.parse(_:)` checks them. Every case but `tooLong` names an
/// `offset`, an index in the header data.
enum MIDICIPropertyHeaderRefusal: Error, Equatable, Hashable, Sendable {
    /// 1. More than `limit` (`MIDICIPropertyChunk.maximumHeaderBytes`) bytes; nothing was read.
    case tooLong(count: Int, limit: Int)
    /// 2. A byte of 0x80 or more; `offset` is the first one's.
    case byteHigh(offset: Int)
    /// 3. The input stops before the document does (empty input included); `offset` is the input's count.
    case unexpectedEnd(offset: Int)
    /// 3. A byte that cannot come next, such as a top level that is not an object or a missing colon.
    case unexpectedByte(offset: Int)
    /// 3. A byte below 0x20 in a string, or (at its backslash) an unknown escape, a bad `\u` escape or a surrogate
    /// without its pair.
    case invalidString(offset: Int)
    /// 3. The first byte that breaks the JSON number grammar, such as the `1` of `01`.
    case invalidNumber(offset: Int)
    /// 3. An object or array that would open level 9 or deeper; `offset` is its bracket.
    case tooDeep(offset: Int)
    /// 3. A name already used in the same object, at any depth; `offset` is its second opening quote.
    case duplicateKey(name: String, offset: Int)
    /// 3. A byte other than whitespace after the top-level object.
    case trailingBytes(offset: Int)
    /// 4. The value of the known key `key` has the wrong JSON type (a fraction or an exponent for an integer field
    /// included); `offset` is the value's first byte.
    case wrongType(key: String, offset: Int)
    /// 4. The integer value of the known key `key` is negative or above 2,147,483,647; `offset` is its first byte.
    case outOfRange(key: String, offset: Int)
}
