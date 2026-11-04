import Foundation
import UniformTypeIdentifiers

struct CastDevice: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let model: String
    let host: String
    let port: Int
    let type: String

    var id: String { "\(name)-\(host)-\(port)" }
    var isAudioTarget: Bool { type == "audio" || type == "group" }
}

struct DeviceList: Codable, Sendable {
    let devices: [CastDevice]
}

struct CastStatus: Codable, Sendable {
    let device: String
    let player: String
    let title: String?
    let currentTime: Double
    let duration: Double?
    let volume: Int
    let muted: Bool
}

struct PlaybackEvent: Codable, Sendable {
    let event: String
    let state: String?
    let source: String?
    let device: String?
    let currentTime: Double?
    let duration: Double?
}

struct Track: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let url: URL
    var resolvedTitle: String?
    /// User-entered name; wins over the title resolved from the website.
    var customTitle: String?

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }

    var title: String {
        customTitle ?? resolvedTitle ?? (url.isFileURL ? url.deletingPathExtension().lastPathComponent : "\(MediaLinks.site(for: url) ?? "Online video") · \(url.lastPathComponent)")
    }

    var subtitle: String {
        if !url.isFileURL { return MediaLinks.site(for: url) ?? "Online media" }
        if url.path.hasPrefix("/Volumes/") { return "Network / External · \(url.pathExtension.uppercased())" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "Audio" : ext
    }

    var isVideo: Bool {
        if !url.isFileURL { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    var source: String { url.isFileURL ? url.path : url.absoluteString }
}

enum RepeatMode: String, Sendable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var symbol: String { self == .one ? "repeat.1" : "repeat" }

    var label: String {
        switch self {
        case .off: "Repeat: Off"
        case .all: "Repeat: Whole playlist"
        case .one: "Repeat: Current track"
        }
    }
}

/// Pure playlist edits, kept out of PlayerModel so they are testable without a Cast backend.
enum PlaylistEditor {
    static func removing(_ ids: Set<Track.ID>, from playlist: [Track]) -> (playlist: [Track], nextSelection: Track.ID?) {
        let firstRemoved = playlist.firstIndex { ids.contains($0.id) }
        let remaining = playlist.filter { !ids.contains($0.id) }
        guard let firstRemoved else { return (remaining, nil) }
        let next = remaining.indices.contains(firstRemoved) ? remaining[firstRemoved].id : remaining.last?.id
        return (remaining, next)
    }

    /// Finder-style name order: case-insensitive, numbers compared numerically ("2" < "10").
    static func sortedByName(_ playlist: [Track], ascending: Bool = true) -> [Track] {
        playlist.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    /// The track after `id`; with `wrapping`, the last track is followed by the first.
    static func nextID(after id: Track.ID, in playlist: [Track], wrapping: Bool) -> Track.ID? {
        guard let index = playlist.firstIndex(where: { $0.id == id }) else { return nil }
        if playlist.indices.contains(index + 1) { return playlist[index + 1].id }
        return wrapping ? playlist.first?.id : nil
    }

    /// What plays when `id` finishes on its own.
    static func autoAdvanceID(after id: Track.ID, in playlist: [Track], mode: RepeatMode) -> Track.ID? {
        if mode == .one { return playlist.contains { $0.id == id } ? id : nil }
        return nextID(after: id, in: playlist, wrapping: mode == .all)
    }

    static func renaming(_ id: Track.ID, to name: String, in playlist: [Track]) -> [Track] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return playlist.map { track in
            guard track.id == id else { return track }
            var renamed = track
            renamed.customTitle = trimmed.isEmpty ? nil : trimmed
            return renamed
        }
    }
}

enum PlayerPhase: Equatable, Sendable {
    case idle
    case discovering
    case transcoding
    case connecting
    case playing
    case paused
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Ready"
        case .discovering: "Finding speakers…"
        case .transcoding: "Preparing audio…"
        case .connecting: "Connecting…"
        case .playing: "Casting"
        case .paused: "Paused"
        case .failed(let message): message
        }
    }

    var isActive: Bool {
        switch self {
        case .transcoding, .connecting, .playing, .paused: true
        default: false
        }
    }
}

enum TimeText {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let rounded = Int(seconds.rounded(.down))
        let hours = rounded / 3_600
        let minutes = (rounded % 3_600) / 60
        let remainder = rounded % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
