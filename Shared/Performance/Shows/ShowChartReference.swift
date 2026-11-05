//
//  ShowChartReference.swift
//  FluxKlang
//
//  A user-owned chart: the `AssetID` of a project `.document` asset, plus an
//  optional page. It holds no URL, path or bytes, so nothing is copied, fetched
//  or executed. Missing content is a recoverable state, never dropped (#106 SH1).
//

struct ChartReference: Hashable, Sendable {
    private let storedAsset: AssetID
    private let storedPage: Int?

    var asset: AssetID { storedAsset }
    var page: Int? { storedPage }

    private init(asset: AssetID, page: Int?) {
        storedAsset = asset
        storedPage = page
    }

    static func make(asset: AssetID, page: Int? = nil) throws(ShowRefusal) -> ChartReference {
        if let page, !(1...ShowLimits.maximumChartPage).contains(page) { throw .invalidChartPage(page) }
        return ChartReference(asset: asset, page: page)
    }
}

enum ChartMissingReason: Hashable, Sendable {
    /// The project lists no asset with this ID.
    case notInProject
    /// The asset exists but is not a document.
    case notDocument(AssetMedia)
    /// The asset is listed but its content is not in the package (for example a stale bookmark).
    case contentUnavailable
}

/// The reference is kept in both states; relinking replaces it.
enum ChartAvailability: Hashable, Sendable {
    case available(ChartReference)
    case missing(ChartReference, ChartMissingReason)

    var reference: ChartReference {
        switch self {
        case let .available(reference), let .missing(reference, _): reference
        }
    }
}
