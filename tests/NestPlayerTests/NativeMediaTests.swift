import AVFoundation
import Foundation
import Testing
@testable import NestPlayer

@Test func nativeRangesHandleBoundsAndRejectAmbiguousInput() {
    #expect(MediaByteRange.parse("bytes=2-5", size: 10) == MediaByteRange(start: 2, length: 4))
    #expect(MediaByteRange.parse("bytes=7-", size: 10) == MediaByteRange(start: 7, length: 3))
    #expect(MediaByteRange.parse("bytes=-40", size: 10) == MediaByteRange(start: 0, length: 10))
    #expect(MediaByteRange.parse("bytes=0-999", size: 10) == MediaByteRange(start: 0, length: 10))
    for invalid in ["bytes=10-", "bytes=-0", "bytes=5-2", "bytes=0-1,3-4", "bytes=+1-2", "bytes=1-18446744073709551616"] {
        #expect(MediaByteRange.parse(invalid, size: 10) == nil)
    }
    #expect(MediaByteRange.parse("bytes=0-", size: 0) == nil)
}

@Test func nativeServerServesRangesAndOnlyItsOpaqueCapability() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp3")
    let contents = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
    try contents.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let (server, url) = try await NativeMediaServer.serve(file: file, contentType: "audio/mpeg")
    defer { server.close() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("bytes=65530-131080", forHTTPHeaderField: "Range")
    let (slice, result) = try await session.data(for: request)
    #expect((result as? HTTPURLResponse)?.statusCode == 206)
    #expect((result as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes 65530-131080/262144")
    #expect(slice == contents.subdata(in: 65530..<131081))

    request.httpMethod = "HEAD"
    let (head, header) = try await session.data(for: request)
    #expect(head.isEmpty)
    #expect((header as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "65551")
    request.httpMethod = "GET"
    request.setValue("bytes=999999-", forHTTPHeaderField: "Range")
    let (_, invalid) = try await session.data(for: request)
    #expect((invalid as? HTTPURLResponse)?.statusCode == 416)
    let (_, denied) = try await session.data(from: url.deletingLastPathComponent().appending(path: "private.mp3"))
    #expect((denied as? HTTPURLResponse)?.statusCode == 404)
    let (all, full) = try await session.data(from: url)
    #expect((full as? HTTPURLResponse)?.statusCode == 200)
    #expect(all == contents)
}

@Test func nativeDirectAudioDoesNotCopyOrCreateConversionCache() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "source.mp3")
    try Data("direct fixture".utf8).write(to: file)
    let cache = root.appending(path: "cache")
    let prepared = try await NativeMediaPreparer(root: cache).prepare(file)
    #expect(prepared.file == file)
    #expect(prepared.contentType == "audio/mpeg")
    #expect(!FileManager.default.fileExists(atPath: cache.path))
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
func nativeVideoExportContainsOnlyAudioAndReusesCache() async throws {
    // FFmpeg generates a tiny test fixture only. The production path uses AVFoundation.
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "fixture.mp4")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    process.arguments = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=size=32x32:rate=10:duration=1", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:v", "libx264", "-c:a", "aac", "-shortest", file.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let preparer = NativeMediaPreparer(root: root.appending(path: "cache"), limit: 1)
    let first = try await preparer.prepare(file)
    #expect(!first.cached)
    try #require(FileManager.default.fileExists(atPath: first.file.path), "Cache pruning must preserve the current oversized item")
    let exported = AVURLAsset(url: first.file)
    #expect(try await exported.loadTracks(withMediaType: .audio).count == 1)
    #expect(try await exported.loadTracks(withMediaType: .video).isEmpty)
    let second = try await preparer.prepare(file)
    #expect(second.cached)
    #expect(first.file == second.file)
    #expect(try Data(contentsOf: first.file).count > 0)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
    let changed = try await preparer.prepare(file)
    #expect(!changed.cached)
    #expect(changed.file != first.file)
    // Keep the current item even if it alone exceeds the configured budget.
    #expect(!FileManager.default.fileExists(atPath: first.file.path))
    #expect(FileManager.default.fileExists(atPath: changed.file.path))
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await preparer.prepare(file)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test func nativeLowRateInputBecomesCastCompatibleAACAndReusesCache() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "low-rate.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050))
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
    do {
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer)
    }
    let preparer = NativeMediaPreparer(root: root.appending(path: "cache"))
    let first = try await preparer.prepare(source)
    let asset = AVURLAsset(url: first.file)
    let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let description = try #require(try await audio.load(.formatDescriptions).first)
    let stream = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
    #expect(stream.mFormatID == kAudioFormatMPEG4AAC)
    #expect(stream.mSampleRate == 48000)
    #expect(stream.mChannelsPerFrame == 1)
    #expect(abs(try await asset.load(.duration).seconds - 1) < 0.1)
    #expect(try await preparer.prepare(source).cached)
    try Data().write(to: first.file)
    let repaired = try await preparer.prepare(source)
    #expect(!repaired.cached)
    #expect(repaired.file == first.file)
    #expect(try Data(contentsOf: repaired.file).count > 0)
    // A compatible M4A can now be used directly without another lossy encode.
    #expect(try await preparer.prepare(first.file).file == first.file)
    // M4A's suffix alone must not bypass normalization of existing low-rate AAC.
    let lowRateM4A = root.appending(path: "low-rate.m4a")
    let legacy = try #require(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A))
    try await legacy.export(to: lowRateM4A, as: .m4a)
    let normalized = try await preparer.prepare(lowRateM4A)
    #expect(normalized.file != lowRateM4A)
    let normalizedAsset = AVURLAsset(url: normalized.file)
    let normalizedTrack = try #require(try await normalizedAsset.loadTracks(withMediaType: .audio).first)
    let normalizedFormat = try #require(try await normalizedTrack.load(.formatDescriptions).first)
    #expect(CMAudioFormatDescriptionGetStreamBasicDescription(normalizedFormat)?.pointee.mSampleRate == 48000)
}

@Test func nativeWriterFinalizationHonorsCancellationBeforeAdmission() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
    defer { try? FileManager.default.removeItem(at: file) }
    let cancelled = Task {
        let writer = try AVAssetWriter(outputURL: file, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        input.markAsFinished()
        withUnsafeCurrentTask { $0?.cancel() }
        do { try await NativeMediaPreparer.finishWriting(writer) }
        catch {
            #expect(writer.status == .cancelled)
            throw error
        }
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}
