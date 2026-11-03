import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation

struct PreparedNativeMedia: Sendable {
    let file: URL
    let contentType: String
    let cached: Bool
}

enum NativeMediaError: LocalizedError {
    case noAudio
    case unsupported
    var errorDescription: String? {
        switch self {
        case .noAudio: "This file has no audio track to cast."
        case .unsupported: "macOS could not read this audio format. Try an MP3, M4A, or an H.264/AAC MP4 file."
        }
    }
}

/// Runs media work off the UI actor. Uses only platform APIs: no Homebrew tool,
/// runtime installer, child file grant, or complete in-memory file copy.
actor NativeMediaPreparer {
    private let root: URL
    private let limit: Int64
    static let directTypes = [
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "flac": "audio/flac",
        "wav": "audio/wav", "ogg": "audio/ogg", "oga": "audio/ogg", "opus": "audio/ogg",
    ]

    init(root: URL? = nil, limit: Int64 = 2 * 1024 * 1024 * 1024) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "NestPlayer/native-media", directoryHint: .isDirectory)
        self.limit = limit
    }

    func prepare(_ source: URL) async throws -> PreparedNativeMedia {
        try Task.checkCancellation()
        // URL.resourceValues may cache metadata on a playlist's long-lived URL.
        // Fetch a fresh filesystem stat so edits really invalidate conversions.
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnsupportedScheme) }
        if let type = Self.directTypes[source.pathExtension.lowercased()] {
            return PreparedNativeMedia(file: source, contentType: type, cached: false)
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fingerprint = "native-audio-v1\u{0}\(source.path)\u{0}\(size)\u{0}\(modified)"
        let key = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appending(path: key + ".m4a")
        if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return PreparedNativeMedia(file: destination, contentType: "audio/mp4", cached: true)
        }

        let asset = AVURLAsset(url: source)
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw NativeMediaError.noAudio }
        let formats = try await audio.load(.formatDescriptions)
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        let canCopy = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2].contains(codec ?? 0)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeMediaError.unsupported
        }
        try track.insertTimeRange(try await audio.load(.timeRange), of: audio, at: .zero)
        try Task.checkCancellation()
        let partial = root.appending(path: ".\(key).\(UUID().uuidString).partial.m4a")
        defer { try? FileManager.default.removeItem(at: partial) }

        // Preserve AAC bytes when possible; transcode only the audio track for
        // other macOS-supported containers/codecs. Never export the video track.
        // https://developer.apple.com/documentation/avfoundation/avassetexportsession/export(to:as:isolation:)
        if canCopy, let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) {
            do { try await session.export(to: partial, as: .m4a) }
            catch {
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: partial)
                try await encode(composition, to: partial)
            }
        } else { try await encode(composition, to: partial) }
        try Task.checkCancellation()
        // An overlapping request may already have completed the same cache key.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        prune(preserving: destination)
        return PreparedNativeMedia(file: destination, contentType: "audio/mp4", cached: false)
    }

    private func encode(_ asset: AVAsset, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NativeMediaError.unsupported
        }
        try await session.export(to: output, as: .m4a)
    }

    private func prune(preserving current: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
        let entries = files.filter { $0.pathExtension == "m4a" }.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        // Directory enumeration may return base-relative URLs. Compare absolute
        // file paths so an equivalent URL cannot evict the active oversized item.
        let currentPath = current.standardizedFileURL.path
        for (url, size, _) in entries.sorted(by: { $0.2 < $1.2 }) where total > limit && url.standardizedFileURL.path != currentPath {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}
