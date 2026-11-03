import Foundation
import Testing
@testable import NestPlayer

@MainActor
private final class BookmarkFixture: FileBookmarkProvider {
    var started: [URL] = []
    var stopped: [URL] = []
    var createFails = false
    var resolveFails = false
    var movedRoot: URL?
    var stale = false

    func create(for url: URL, securityScoped: Bool) throws -> Data {
        if createFails { throw CocoaError(.fileWriteNoPermission) }
        return Data(url.path.utf8)
    }

    func resolve(_ data: Data, securityScoped: Bool) throws -> ResolvedFileBookmark {
        if resolveFails { throw CocoaError(.fileReadNoSuchFile) }
        return ResolvedFileBookmark(url: movedRoot ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: stale)
    }

    func start(_ url: URL) -> Bool { started.append(url); return true }
    func stop(_ url: URL) { stopped.append(url) }
}

@Test @MainActor func selectedFolderGrantPersistsAndBalancesAccessLifetime() throws {
    let suite = "NestPlayer.FileAccess.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = BookmarkFixture()
    let root = URL(fileURLWithPath: "/Volumes/Media/Music", isDirectory: true)
    let store = FileAccessStore(defaults: defaults, securityScoped: true, provider: fixture)
    try store.authorize(root, isDirectory: true)
    let nested = root.appending(path: "Album/song.mp3")
    #expect(try store.readableURL(for: nested) == nested)
    #expect(fixture.started.count == 1)
    #expect(fixture.stopped.isEmpty)
    #expect(throws: FileAccessError.self) {
        try store.readableURL(for: URL(fileURLWithPath: "/Volumes/Media/Music2/song.mp3"))
    }
    store.close()
    store.close()
    #expect(fixture.stopped == [root])

    let restored = FileAccessStore(defaults: defaults, securityScoped: true, provider: fixture)
    #expect(fixture.started.count == 1) // Restore is lazy, including offline shares.
    #expect(try restored.readableURL(for: nested) == nested)
    #expect(fixture.started.count == 2)
    restored.close()
    #expect(fixture.stopped.count == 2)
}

@Test @MainActor func movedFolderBookmarksMapBothSavedAndNewlyScannedPaths() throws {
    let suite = "NestPlayer.FileMove.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = BookmarkFixture()
    let original = URL(fileURLWithPath: "/Volumes/OldName/Music", isDirectory: true)
    let moved = URL(fileURLWithPath: "/Volumes/NewName/Music", isDirectory: true)
    let initial = FileAccessStore(defaults: defaults, securityScoped: true, provider: fixture)
    try initial.authorize(original, isDirectory: true)
    initial.close()
    fixture.movedRoot = moved
    fixture.stale = true
    let restored = FileAccessStore(defaults: defaults, securityScoped: true, provider: fixture)
    #expect(try restored.readableURL(for: original.appending(path: "song.mp3")) == moved.appending(path: "song.mp3"))
    #expect(try restored.readableURL(for: moved.appending(path: "song.mp3")) == moved.appending(path: "song.mp3"))
    restored.close()
}

@Test @MainActor func unavailableShareDoesNotEraseItsBookmark() throws {
    let suite = "NestPlayer.FileOffline.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = BookmarkFixture()
    let folder = URL(fileURLWithPath: "/Volumes/NAS/Music", isDirectory: true)
    let initial = FileAccessStore(defaults: defaults, securityScoped: true, provider: fixture)
    try initial.authorize(folder, isDirectory: true)
    initial.close()
    fixture.resolveFails = true
    let offline = FileAccessStore(defaults: defaults, securityScoped: true, provider: fixture)
    #expect(throws: (any Error).self) { try offline.readableURL(for: folder.appending(path: "song.mp3")) }
    fixture.resolveFails = false
    #expect(try offline.readableURL(for: folder.appending(path: "song.mp3")) == folder.appending(path: "song.mp3"))
    offline.close()
}

@Test @MainActor func failedBookmarkCreationReleasesTemporaryAccess() throws {
    let suite = "NestPlayer.FileFailure.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = BookmarkFixture()
    fixture.createFails = true
    let store = FileAccessStore(defaults: defaults, securityScoped: true, provider: fixture)
    let file = URL(fileURLWithPath: "/tmp/fixture.mp3")
    #expect(throws: (any Error).self) { try store.authorize(file, isDirectory: false) }
    #expect(fixture.started == fixture.stopped)
    store.close()
    #expect(fixture.stopped.count == 1)
}

@Test func bookmarkGrantDoesNotCoverSiblingPathsOrEscapeThroughDotDot() {
    let grant = FileAccessRecord(originalURL: URL(fileURLWithPath: "/Music", isDirectory: true), isDirectory: true, bookmark: Data())
    #expect(grant.relativePath(for: URL(fileURLWithPath: "/Music/Album/a.mp3")) == "Album/a.mp3")
    #expect(grant.relativePath(for: URL(fileURLWithPath: "/Music2/a.mp3")) == nil)
    #expect(grant.relativePath(for: URL(fileURLWithPath: "/Music/../Private/a.mp3")) == nil)
}

@Test @MainActor func systemBookmarkRoundTripsARealFileWithoutSandboxAssumptions() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("bookmark fixture".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let provider = SystemFileBookmarkProvider()
    let data = try provider.create(for: file, securityScoped: false)
    let resolved = try provider.resolve(data, securityScoped: false)
    #expect(resolved.url.standardizedFileURL == file.standardizedFileURL)
    #expect(try Data(contentsOf: resolved.url) == Data("bookmark fixture".utf8))
}
