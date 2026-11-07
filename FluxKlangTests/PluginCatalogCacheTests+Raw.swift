import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Hand-built bytes that follow the documented layout, so layout tests do not reuse the writer under test.
extension PluginCatalogCacheTests {
    enum Raw {
        static let magic: [UInt8] = [0x46, 0x58, 0x50, 0x43]
        static let aufx: UInt32 = 0x6175_6678
        static let fxkl: UInt32 = 0x4678_6B6C

        static func big<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            (0..<(T.bitWidth / 8)).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }

        static func code(_ text: String) -> UInt32 {
            text.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }

        static func text(_ value: String) -> [UInt8] {
            big(UInt16(value.utf8.count)) + Array(value.utf8)
        }

        static func counted(_ channels: [UInt8]) -> [UInt8] {
            [UInt8(channels.count)] + channels
        }

        /// Published FNV-1a 64 definition, written out again so the fixtures do not call production.
        static func fnv(_ bytes: [UInt8]) -> UInt64 {
            bytes.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
        }

        static func stamp(
            os osText: [UInt8] = text("27.0"), host hostText: [UInt8] = text("1A1"), generation: UInt64 = 5
        ) -> [UInt8] {
            osText + hostText + big(generation)
        }

        static func descriptor(
            name: [UInt8] = text("Plugin"), maker: [UInt8] = text("Maker"), version: UInt32 = 0x0001_0203,
            inputs: [UInt8] = counted([2]), outputs: [UInt8] = counted([2]), flags: UInt8 = 0
        ) -> [UInt8] {
            name + maker + big(version) + inputs + outputs + [flags]
        }

        // swiftlint:disable:next nesting
        typealias Entry = PLG5RawCacheEntry

        static func payload(_ stamp: [UInt8] = Raw.stamp(), count: UInt32? = nil, entries: [Entry]) -> [UInt8] {
            stamp + big(count ?? UInt32(entries.count)) + entries.flatMap(\.bytes)
        }

        /// A complete frame; `length` and `checksum` override the honest values for refusal tests.
        static func frame(
            _ payload: [UInt8], magic: [UInt8] = Raw.magic, version: UInt16 = 1, length: UInt32? = nil
        ) -> [UInt8] {
            let head = magic + big(version) + big(length ?? UInt32(payload.count)) + payload
            return head + big(fnv(head))
        }

        static func frame(entries: [Entry]) -> [UInt8] {
            frame(payload(entries: entries))
        }

        /// Recomputes the trailer after a test edited bytes inside the frame.
        static func resealed(_ bytes: [UInt8]) -> [UInt8] {
            let head = Array(bytes.dropLast(8))
            return head + big(fnv(head))
        }
    }

    static func decode(_ bytes: [UInt8]) throws -> PluginCatalogSnapshot {
        try PluginCatalogSnapshot.decode(from: Data(bytes))
    }

    /// The refusal `decode` raises for `bytes`, or `nil` when it unexpectedly accepts them.
    static func refusal(_ bytes: [UInt8]) -> PluginCatalogCacheError? {
        do throws(PluginCatalogCacheError) {
            _ = try PluginCatalogSnapshot.decode(from: Data(bytes))
            return nil
        } catch {
            return error
        }
    }
}

/// One entry of the documented layout, every field overridable so tests can write defects.
struct PLG5RawCacheEntry {
    typealias Raw = PluginCatalogCacheTests.Raw

    var format: UInt8 = 0
    var type = Raw.aufx
    var subtype: UInt32
    var manufacturer = Raw.fxkl
    var presence: [UInt8] = [0]
    var quarantine: UInt8 = 0
    var descriptorFlag: UInt8?
    var descriptor: [UInt8]? = Raw.descriptor()

    init(_ subtype: String) {
        self.subtype = Raw.code(subtype)
    }

    var bytes: [UInt8] {
        [format] + Raw.big(type) + Raw.big(subtype) + Raw.big(manufacturer) + presence + [quarantine]
            + [descriptorFlag ?? (descriptor == nil ? 0 : 1)] + (descriptor ?? [])
    }
}
