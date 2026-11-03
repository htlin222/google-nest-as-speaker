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
        let ext = source.pathExtension.lowercased()
        if ext != "m4a", let type = Self.directTypes[ext] {
            return PreparedNativeMedia(file: source, contentType: type, cached: false)
        }
        let asset = AVURLAsset(url: source)
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw NativeMediaError.noAudio }
        let formats = try await audio.load(.formatDescriptions)
        let format = formats.first
        let codec = format.map { CMFormatDescriptionGetMediaSubType($0) }
        let description = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = description?.mChannelsPerFrame ?? 2
        // AAC exported at 22.05 kHz can reach PLAYING then fail with receiver
        // MEDIA_DECODE (102). Restrict passthrough to common mono/stereo rates.
        let canCopy = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2].contains(codec ?? 0)
            && [44100.0, 48000.0].contains(description?.mSampleRate ?? 0)
            && (1...2).contains(channels)
        if ext == "m4a", canCopy {
            return PreparedNativeMedia(file: source, contentType: "audio/mp4", cached: false)
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fingerprint = "native-audio-v3\u{0}\(source.path)\u{0}\(size)\u{0}\(modified)"
        let key = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appending(path: key + ".m4a")
        if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return PreparedNativeMedia(file: destination, contentType: "audio/mp4", cached: true)
        }

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
            session.shouldOptimizeForNetworkUse = true
            do { try await session.export(to: partial, as: .m4a) }
            catch {
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: partial)
                try await encode(composition, track: track, channels: channels, to: partial)
            }
        } else { try await encode(composition, track: track, channels: channels, to: partial) }
        try Task.checkCancellation()
        // An overlapping request may already have completed the same cache key.
        let existing = try? FileManager.default.attributesOfItem(atPath: destination.path)
        if (existing?[.size] as? NSNumber)?.uint64Value ?? 0 == 0 {
            if existing != nil { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        prune(preserving: destination)
        return PreparedNativeMedia(file: destination, contentType: "audio/mp4", cached: false)
    }

    private func encode(_ asset: AVAsset, track: AVAssetTrack, channels sourceChannels: UInt32, to output: URL) async throws {
        // AppleM4A's preset preserves the input sample rate. Explicit PCM reader
        // settings resample once, in bounded sample buffers, before AAC encoding.
        // https://developer.apple.com/documentation/avfoundation/avassetreaderaudiomixoutput/init(audiotracks:audiosettings:)
        let channels = sourceChannels == 1 ? 1 : 2
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        samples.alwaysCopiesSampleData = false
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels * 64000,
        ])
        guard reader.canAdd(samples), writer.canAdd(input) else {
            throw NativeMediaError.unsupported
        }
        reader.add(samples)
        writer.add(input)
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? NativeMediaError.unsupported
        }
        writer.startSession(atSourceTime: .zero)
        while true {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? NativeMediaError.unsupported }
            if !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            let appended: Bool? = autoreleasepool {
                guard let buffer = samples.copyNextSampleBuffer() else { return nil }
                return input.append(buffer)
            }
            guard let appended else { break }
            guard appended else { throw writer.error ?? NativeMediaError.unsupported }
        }
        guard reader.status == .completed else { throw reader.error ?? NativeMediaError.unsupported }
        input.markAsFinished()
        try await Self.finishWriting(writer)
        guard writer.status == .completed else { throw writer.error ?? NativeMediaError.unsupported }
    }

    static func finishWriting(_ writer: AVAssetWriter, isolation: isolated (any Actor)? = #isolation) async throws {
        try await AudioWriterFinalizer(writer).finish()
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

/// Exclusive access transfers here after all sample appends have returned. The
/// caller must not touch the writer until finish returns. All finish/cancel
/// admission is serialized on this queue; callbacks only resume continuation.
/// Do not extend this boundary across append/copy, which forbid concurrent cancel.
private final class AudioWriterFinalizer: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let queue = DispatchQueue(label: "NestPlayer.audio-finalize")

    init(_ writer: AVAssetWriter) { self.writer = writer }

    func finish() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    guard self.writer.status == .writing else { continuation.resume(); return }
                    self.writer.finishWriting { continuation.resume() }
                }
            }
        } onCancel: {
            self.queue.async {
                if self.writer.status == .writing { self.writer.cancelWriting() }
            }
        }
        try Task.checkCancellation()
    }
}
