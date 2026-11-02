import AppKit
import Foundation

enum MediaLinks {
    static func site(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if matches(host, "youtube.com") || matches(host, "youtu.be") { return "YouTube" }
        if matches(host, "bilibili.com") || matches(host, "b23.tv") || matches(host, "bili2233.cn") { return "Bilibili" }
        return nil
    }

    private static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    static func normalize(_ url: URL) -> URL? {
        guard ["https", "http"].contains(url.scheme?.lowercased()), site(for: url) != nil,
              url.user == nil, url.password == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        components.fragment = nil
        let host = url.host?.lowercased() ?? ""
        if matches(host, "youtube.com") || matches(host, "youtu.be") {
            let paths = url.pathComponents.filter { $0 != "/" }
            let videoID: String?
            if matches(host, "youtu.be") { videoID = paths.first }
            else if ["shorts", "embed", "live"].contains(paths.first ?? "") { videoID = paths.dropFirst().first }
            else { videoID = components.queryItems?.first { $0.name == "v" }?.value }
            guard let videoID, !videoID.isEmpty,
                  videoID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return nil }
            components.host = "www.youtube.com"
            components.path = "/watch"
            components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        } else if matches(host, "bilibili.com") {
            guard url.path.contains("/video/") || url.path.contains("/bangumi/play/") else { return nil }
            components.host = "www.bilibili.com"
            components.queryItems = components.queryItems?.filter { $0.name == "p" }
        } else {
            components.query = nil
        }
        return components.url
    }

    static func parse(_ text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let normalized = normalize(url), seen.insert(normalized.absoluteString).inserted else { return nil }
            return normalized
        }
    }
}

enum SMBAddress {
    static func parse(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "smb", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return nil }
        return url
    }
}

struct BrowserSession: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleID: String

    static let choices = [
        BrowserSession(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome"),
        BrowserSession(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        BrowserSession(id: "brave", name: "Brave", bundleID: "com.brave.Browser"),
        BrowserSession(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox"),
        BrowserSession(id: "chromium", name: "Chromium", bundleID: "org.chromium.Chromium"),
        BrowserSession(id: "safari", name: "Safari", bundleID: "com.apple.Safari"),
    ]

    @MainActor static var installed: [BrowserSession] {
        choices.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}

struct WebsiteLoginRequest: Identifiable {
    let id = UUID()
    let track: Track
    let message: String
    var site: String { MediaLinks.site(for: track.url) ?? "Website" }
}

struct FolderScan: Sendable {
    let urls: [URL]
    let truncated: Bool
}

enum MediaFolderScanner {
    static let extensions: Set<String> = [
        "aac", "aif", "aiff", "alac", "flac", "m4a", "mp3", "ogg", "oga", "opus", "wav", "wma",
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "mpeg", "mpg", "ts", "mts", "m2ts",
    ]

    static func scan(_ folder: URL, limit: Int = 10_000) throws -> FolderScan {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard FileManager.default.isReadableFile(atPath: folder.path),
              let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            files.append(url)
            if files.count >= limit { return FolderScan(urls: sorted(files), truncated: true) }
        }
        return FolderScan(urls: sorted(files), truncated: false)
    }

    private static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
