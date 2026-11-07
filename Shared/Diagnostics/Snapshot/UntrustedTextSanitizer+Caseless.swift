//
//  UntrustedTextSanitizer+Caseless.swift
//  FluxKlang
//
//  The canonical caseless form (Unicode D145) that withheld strings and labels are
//  matched in, and its map back to the source scalars of a label.
//

import Foundation

extension UntrustedTextSanitizer {
    /// The canonical caseless form NFD(fold(NFD(text))) of Unicode D145, the one
    /// form both terms and labels are matched in. `fold` is full case folding.
    static func caselessForm(_ text: some Sequence<Unicode.Scalar>) -> [Unicode.Scalar] {
        let scalars = Array(text)
        if scalars.allSatisfy(\.isASCII) { return scalars.flatMap(fold) }
        let decomposed = String(String.UnicodeScalarView(scalars)).decomposedStringWithCanonicalMapping
        let folded = String.UnicodeScalarView(decomposed.unicodeScalars.flatMap(fold))
        return Array(String(folded).decomposedStringWithCanonicalMapping.unicodeScalars)
    }

    /// `text` without the spaces whose ordinals among its U+0020 scalars are in
    /// `separators` (see `Scan.separators`).
    static func dropping(_ separators: [Int], from text: String) -> String {
        let dropped = Set(separators)
        var kept = String.UnicodeScalarView()
        var ordinal = 0
        for scalar in text.unicodeScalars {
            if scalar == " " {
                ordinal += 1
                if dropped.contains(ordinal - 1) { continue }
            }
            kept.append(scalar)
        }
        return String(kept)
    }

    /// The caseless form of a source text, with every caseless scalar mapped to
    /// the source scalar range of the grapheme that contains it.
    ///
    /// It is built grapheme by grapheme, which equals the caseless form of the
    /// complete text: NFD only reorders runs of nonstarters (ccc ≠ 0), and every
    /// nonstarter extends the grapheme before it except after a control, line or
    /// paragraph separator, which `filterScalars` has replaced with a space. Case
    /// folding is per scalar and its output is already NFD; only U+0345 changes
    /// class (240 to ι), and nothing it could reorder past follows it. Checked over
    /// every scalar on this toolchain (`NeutralSnapshotUnicodeScanTests`), and
    /// `caselessMapMatchesTheWholeText` pins it for the test corpus.
    ///
    /// `dropping` lists spaces (ordinals among the text's U+0020 scalars) that are left
    /// out, so the map is the caseless form of `dropping(separators, from: text)`. A
    /// grapheme that is only a dropped space maps nothing (a match next to it does not
    /// widen into it). One that also holds other scalars (marks on the space) joins them
    /// to the graphemes before it, which are folded together with them (NFD may reorder
    /// them in among those graphemes' marks), and every scalar of the joined run maps to
    /// the whole run.
    struct CaselessMap {
        private(set) var scalars: [Unicode.Scalar] = []
        private(set) var graphemeStart: [Int] = []
        private(set) var graphemeEnd: [Int] = []
        private(set) var sourceCount = 0

        init(_ text: String, dropping separators: [Int] = []) {
            let dropped = Set(separators)
            var ordinal = 0
            var run: [Unicode.Scalar] = []
            var source = 0..<0
            for grapheme in text {
                let start = sourceCount
                sourceCount += grapheme.unicodeScalars.count
                var rest: [Unicode.Scalar] = []
                var joins = false
                for scalar in grapheme.unicodeScalars {
                    if scalar == " " {
                        ordinal += 1
                        if dropped.contains(ordinal - 1) {
                            joins = true
                            continue
                        }
                    }
                    rest.append(scalar)
                }
                if !joins {
                    append(run, from: source)
                    run = []
                }
                guard !rest.isEmpty else { continue }
                source = (run.isEmpty ? start : source.lowerBound)..<sourceCount
                run += rest
            }
            append(run, from: source)
        }

        private mutating func append(_ run: [Unicode.Scalar], from source: Range<Int>) {
            let form = UntrustedTextSanitizer.caselessForm(run)
            scalars.append(contentsOf: form)
            graphemeStart.append(contentsOf: repeatElement(source.lowerBound, count: form.count))
            graphemeEnd.append(contentsOf: repeatElement(source.upperBound, count: form.count))
        }
    }

    /// Full case folding per scalar, the same function for terms and labels: the
    /// lowercase mapping of the uppercase mapping, repeated to a fixed point (at most
    /// `maximumFoldRounds`). One round is not enough: `ẞ` gives `ß`, and only the
    /// second round gives `ss`. Lengths may change, which is why matches are mapped
    /// back through a source index.
    ///
    /// Checked against CaseFolding.txt (statuses C and F) over every scalar the
    /// toolchain assigns: two scalars fold equal here exactly when they do under C+F,
    /// except that dotless `ı` also folds with `i` (over-redaction only). Scalars the
    /// toolchain leaves unassigned are removed by `filterScalars` before matching.
    /// `String.folding(options: .caseInsensitive)` was not used: per character it
    /// leaves U+1C80–U+1C88 unfolded, which C+F folds to Cyrillic lowercase.
    static func fold(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        if scalar.isASCII {
            let value = UInt8(scalar.value)
            return [Unicode.Scalar((65...90).contains(value) ? value + 32 : value)]
        }
        var folding = [scalar]
        for _ in 0..<maximumFoldRounds {
            let next = folding.flatMap(\.properties.uppercaseMapping.unicodeScalars)
                .flatMap(\.properties.lowercaseMapping.unicodeScalars)
            if next == folding { break }
            folding = next
        }
        return folding
    }

    /// Every scalar reaches its fixed point within two rounds; three leaves a margin.
    /// `NeutralSnapshotUnicodeScanTests` checks every scalar against it.
    static let maximumFoldRounds = 3
}
