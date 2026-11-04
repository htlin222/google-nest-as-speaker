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

enum RepeatMode: String, Codable, Sendable {
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

struct Playlist: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var name: String
    var tracks: [Track]
    var repeatMode: RepeatMode
    /// Where to continue: the last track played and its position in seconds.
    var resumeTrackID: Track.ID?
    var resumePosition: Double

    init(id: UUID = UUID(), name: String, tracks: [Track] = [], repeatMode: RepeatMode = .off) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.repeatMode = repeatMode
        resumeTrackID = nil
        resumePosition = 0
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        repeatMode = try container.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
        resumeTrackID = try container.decodeIfPresent(UUID.self, forKey: .resumeTrackID)
        resumePosition = try container.decodeIfPresent(Double.self, forKey: .resumePosition) ?? 0
    }

    /// Seconds to start `trackID` at; short offsets restart from the beginning.
    func resumeStart(for trackID: Track.ID) -> Double {
        trackID == resumeTrackID && resumePosition >= 5 ? resumePosition : 0
    }
}

/// Every named playlist plus which one is shown. Always holds at least one playlist.
struct PlaylistLibrary: Codable, Sendable, Equatable {
    static let defaultName = "預設"

    private(set) var playlists: [Playlist]
    private(set) var currentID: Playlist.ID

    init(playlists: [Playlist], currentID: Playlist.ID? = nil) {
        let list = playlists.isEmpty ? [Playlist(name: Self.defaultName)] : playlists
        self.playlists = list
        self.currentID = currentID.flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list[0].id
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            playlists: try container.decode([Playlist].self, forKey: .playlists),
            currentID: try container.decodeIfPresent(UUID.self, forKey: .currentID)
        )
    }

    /// Wraps the pre-library single playlist so upgrading keeps every track.
    static func migrating(legacyTracks: [Track], repeatMode: RepeatMode) -> PlaylistLibrary {
        PlaylistLibrary(playlists: [Playlist(name: defaultName, tracks: legacyTracks, repeatMode: repeatMode)])
    }

    private var currentIndex: Int { playlists.firstIndex { $0.id == currentID } ?? 0 }

    var current: Playlist {
        get { playlists[currentIndex] }
        set { playlists[currentIndex] = newValue }
    }

    func uniqueName(_ proposed: String, excluding id: Playlist.ID? = nil) -> String {
        let base = proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "New Playlist" : proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(playlists.filter { $0.id != id }.map(\.name))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    @discardableResult
    mutating func create(named name: String) -> Playlist.ID {
        let playlist = Playlist(name: uniqueName(name))
        playlists.append(playlist)
        currentID = playlist.id
        return playlist.id
    }

    mutating func rename(_ id: Playlist.ID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = uniqueName(name, excluding: id)
    }

    /// Refuses to delete the last playlist; selects the neighbour of a deleted current one.
    mutating func delete(_ id: Playlist.ID) {
        guard playlists.count > 1, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists.remove(at: index)
        if currentID == id { currentID = playlists[min(index, playlists.count - 1)].id }
    }

    mutating func select(_ id: Playlist.ID) {
        if playlists.contains(where: { $0.id == id }) { currentID = id }
    }

    /// Copies tracks into another playlist with fresh IDs, skipping sources it already has.
    @discardableResult
    mutating func copy(_ tracks: [Track], to id: Playlist.ID) -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        var seen = Set(playlists[index].tracks.map(\.source))
        let additions = tracks.compactMap { track -> Track? in
            guard seen.insert(track.source).inserted else { return nil }
            var copy = Track(url: track.url)
            copy.resolvedTitle = track.resolvedTitle
            copy.customTitle = track.customTitle
            return copy
        }
        playlists[index].tracks.append(contentsOf: additions)
        return additions.count
    }
}

enum SleepTimerChoice: Hashable, Sendable {
    case minutes(Int)
    case endOfTrack

    static let presets = [15, 30, 45, 60, 90]

    /// Phone-remote encoding: minutes as digits, or "track".
    init?(remoteValue: String) {
        if remoteValue == "track" {
            self = .endOfTrack
        } else if let minutes = Int(remoteValue), Self.presets.contains(minutes) {
            self = .minutes(minutes)
        } else {
            return nil
        }
    }

    var remoteValue: String {
        switch self {
        case .minutes(let minutes): String(minutes)
        case .endOfTrack: "track"
        }
    }

    var label: String {
        switch self {
        case .minutes(let minutes): "\(minutes) minutes"
        case .endOfTrack: "End of current track"
        }
    }
}

/// Linear fade over the sleep timer's last seconds.
enum SleepFade {
    static let duration: Double = 30

    /// Volume (0–100) to use with `remaining` seconds left, or nil before the fade starts.
    static func volume(original: Double, remaining: Double) -> Double? {
        guard remaining < duration else { return nil }
        return (original * min(max(remaining, 0), duration) / duration).rounded()
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
