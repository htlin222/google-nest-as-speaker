import Foundation

struct FileAccessRecord: Codable, Equatable, Sendable {
    let originalURL: URL
    let isDirectory: Bool
    var bookmark: Data

    /// Match whole path components; a grant for /Music must not cover /Music2.
    func relativePath(for candidate: URL) -> String? {
        guard candidate.isFileURL else { return nil }
        let root = originalURL.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        if root == path { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard isDirectory, path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

struct ResolvedFileBookmark {
    let url: URL
    let stale: Bool
}

@MainActor
protocol FileBookmarkProvider {
    func create(for url: URL, securityScoped: Bool) throws -> Data
    func resolve(_ data: Data, securityScoped: Bool) throws -> ResolvedFileBookmark
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
}

@MainActor
struct SystemFileBookmarkProvider: FileBookmarkProvider {
    func create(for url: URL, securityScoped: Bool) throws -> Data {
        let options: URL.BookmarkCreationOptions = securityScoped
            ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : []
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ data: Data, securityScoped: Bool) throws -> ResolvedFileBookmark {
        // Do not mount an offline NAS or present permission UI automatically.
        // https://developer.apple.com/documentation/foundation/url/bookmarkresolutionoptions
        var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        if securityScoped { options.insert(.withSecurityScope) }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        return ResolvedFileBookmark(url: url, stale: stale)
    }

    func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

enum FileAccessError: LocalizedError {
    case permissionRequired(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired(let name):
            "Choose \(name) or its parent folder again using Add Files / Add Folder. If it is on SMB, reconnect the share in Finder first."
        }
    }
}

/// Owns grants for the lifetime of the native process. This does not claim to
/// transfer sandbox extensions to a helper process; that is a separate boundary.
@MainActor
final class FileAccessStore {
    private static let defaultsKey = "selectedMediaBookmarksV1"
    private let defaults: UserDefaults
    private let provider: any FileBookmarkProvider
    private let securityScoped: Bool
    private var records: [FileAccessRecord]
    private var active: [String: URL] = [:]

    static var requiresSecurityScope: Bool {
        #if APP_STORE
        true
        #else
        false
        #endif
    }

    init(
        defaults: UserDefaults = .standard,
        securityScoped: Bool = FileAccessStore.requiresSecurityScope,
        provider: any FileBookmarkProvider = SystemFileBookmarkProvider()
    ) {
        self.defaults = defaults
        self.provider = provider
        self.securityScoped = securityScoped
        records = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([FileAccessRecord].self, from: $0) } ?? []
        // Resolve on demand. Thousands of bookmarks or an offline NAS must not
        // hold up launch. A failed resolution never erases the stored grant.
    }

    func authorize(_ url: URL, isDirectory: Bool? = nil) throws {
        guard url.isFileURL else { return }
        let normalized = url.standardizedFileURL
        if let match = matchingRecord(for: normalized), (try? activate(match.index)) != nil { return }

        let started = provider.start(normalized)
        do {
            let data = try provider.create(for: normalized, securityScoped: securityScoped)
            let directory = isDirectory ?? ((try? normalized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            let record = FileAccessRecord(originalURL: normalized, isDirectory: directory, bookmark: data)
            if let index = records.firstIndex(where: { $0.originalURL.standardizedFileURL == normalized }) {
                records[index] = record
            } else {
                records.append(record)
            }
            if started {
                if let previous = active.updateValue(normalized, forKey: normalized.path) { provider.stop(previous) }
            }
            persist()
        } catch {
            if started { provider.stop(normalized) }
            throw error
        }
    }

    func readableURL(for original: URL) throws -> URL {
        guard original.isFileURL else { return original }
        guard let match = matchingRecord(for: original) else {
            if securityScoped { throw FileAccessError.permissionRequired(original.lastPathComponent) }
            return original
        }
        let base = try activate(match.index)
        return match.relative.isEmpty ? base : base.appending(path: match.relative)
    }

    func close() {
        for url in active.values { provider.stop(url) }
        active.removeAll()
    }

    private func matchingRecord(for url: URL) -> (index: Int, relative: String)? {
        records.indices.compactMap { index -> (index: Int, relative: String)? in
            let record = records[index]
            if let relative = record.relativePath(for: url) { return (index, relative) }
            if let resolved = active[record.originalURL.path] {
                let current = FileAccessRecord(originalURL: resolved, isDirectory: record.isDirectory, bookmark: record.bookmark)
                if let relative = current.relativePath(for: url) { return (index, relative) }
            }
            return nil
        }.max { records[$0.index].originalURL.path.count < records[$1.index].originalURL.path.count }
    }

    private func activate(_ index: Int) throws -> URL {
        let key = records[index].originalURL.path
        if let existing = active[key] { return existing }
        let resolved = try provider.resolve(records[index].bookmark, securityScoped: securityScoped)
        let started = provider.start(resolved.url)
        if securityScoped && !started {
            throw FileAccessError.permissionRequired(records[index].originalURL.lastPathComponent)
        }
        if started { active[key] = resolved.url }
        if resolved.stale {
            // A refresh failure must not revoke otherwise valid current access.
            if let data = try? provider.create(for: resolved.url, securityScoped: securityScoped) {
                records[index].bookmark = data
                persist()
            }
        }
        return resolved.url
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
