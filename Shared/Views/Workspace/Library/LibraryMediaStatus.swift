//
//  LibraryMediaStatus.swift
//  FluxKlang
//
//  Whether the content of a Library chart or media asset is available (#99 LIB4; library-inspector.md "Library"
//  mock: "Stale bookmark"). Decided only by the caller's set of available content: the Library does not tell a stale
//  bookmark from absent bytes. Nothing calls it yet.
//

enum LibraryMediaStatus: Hashable, Sendable {
    case available
    case staleBookmark
}
