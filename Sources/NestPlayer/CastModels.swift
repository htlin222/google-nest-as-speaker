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

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }

    var title: String {
        resolvedTitle ?? (url.isFileURL ? url.deletingPathExtension().lastPathComponent : "\(MediaLinks.site(for: url) ?? "Online video") · \(url.lastPathComponent)")
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
