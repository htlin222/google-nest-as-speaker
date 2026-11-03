#if DEBUG && APP_STORE
import AVFoundation
import Foundation

/// Explicit developer probes. Normal/LAN probes never play media. The separately
/// requested silence probe requires an idle, explicitly named speaker.
enum BackendSmoke {
    static func start(verifyLAN: Bool = false, expectedSpeaker: String? = nil, playSilence: Bool = false) {
        Task.detached {
            // A stopped service must fail this probe instead of leaving CI hanging.
            Task.detached {
                try? await Task.sleep(for: .seconds(playSilence ? 45 : 20))
                finish(ok: false, detail: "Service probe timed out")
            }
            do {
                try await probe(verifyLAN: verifyLAN, expectedSpeaker: expectedSpeaker, playSilence: playSilence)
                finish(ok: true, detail: playSilence
                    ? "Sandboxed native audio reached PLAYING and FINISHED on the expected Cast speaker; volume unchanged"
                    : verifyLAN
                    ? "Sandboxed runtime, live Cast discovery, phone HTTP, native export/cache and ranges passed"
                    : "Sandboxed service, phone HTTP, native audio export/cache and byte ranges passed")
            } catch {
                finish(ok: false, detail: error.localizedDescription)
            }
        }
    }

    private static func probe(verifyLAN: Bool, expectedSpeaker: String?, playSilence: Bool) async throws {
        let backend = try CastBackend()
        defer { backend.shutdown() }
        let inventoryURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/NestCastService.app/Contents/Resources/DependencyInventory.json")
        let inventory = try JSONSerialization.jsonObject(with: Data(contentsOf: inventoryURL)) as? [String: Any]
        let actual = try await backend.request("runtimeInfo")
        guard actual.pythonVersion == inventory?["pythonVersion"] as? String,
              actual.opensslVersion == inventory?["opensslVersion"] as? String,
              actual.expatVersion == inventory?["expatVersion"] as? String else {
            throw CastBackendError.commandFailed("Running helper differs from the packaged runtime inventory")
        }
        var target: CastDevice?
        if verifyLAN || playSilence {
            let discovery = try await backend.request("list", fields: ["timeout": .number(5)])
            let devices = (discovery.devices ?? []).filter(\.isAudioTarget)
            guard !devices.isEmpty, expectedSpeaker == nil || devices.contains(where: { $0.name == expectedSpeaker }) else {
                throw CastBackendError.commandFailed("Expected local Cast speaker was not found by the sandboxed app")
            }
            target = devices.first { $0.name == expectedSpeaker }
        }
        let response = try await backend.request("remoteInfo")
        guard let text = response.remoteURL, let url = URL(string: text) else {
            throw CastBackendError.commandFailed("Remote service returned no URL")
        }
        let (_, result) = try await URLSession.shared.data(from: url)
        guard (result as? HTTPURLResponse)?.statusCode == 200 else {
            throw CastBackendError.commandFailed("Remote HTTP probe failed")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "native-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSilentFixture(in: root, seconds: playSilence ? 5 : 0.1,
                                          sampleRate: 22050, channels: 1)
        let preparer = NativeMediaPreparer(root: root.appending(path: "cache"))
        let media = try await preparer.prepare(source)
        guard try await preparer.prepare(source).cached else {
            throw CastBackendError.commandFailed("Native cache was not reused")
        }
        let served = try await NativeMediaServer.serve(file: media.file, contentType: media.contentType)
        defer { served.server.close() }
        var request = URLRequest(url: served.url)
        request.setValue("bytes=0-31", forHTTPHeaderField: "Range")
        let (bytes, rangeResult) = try await URLSession.shared.data(for: request)
        guard (rangeResult as? HTTPURLResponse)?.statusCode == 206, bytes.count == 32 else {
            throw CastBackendError.commandFailed("Native byte-range probe failed")
        }
        if playSilence {
            guard let target else { throw CastBackendError.commandFailed("Silence probe requires --expected-speaker") }
            let before = try await backend.request("status", fields: ["device": .string(target.name), "fresh": .boolean(true)])
            guard before.probeIdle == true else {
                throw CastBackendError.commandFailed("Speaker is occupied; no test playback was started")
            }
            let (events, continuation) = AsyncStream<BackendMessage>.makeStream()
            backend.setEventHandler { continuation.yield($0) }
            defer { continuation.finish() }
            _ = try await backend.request("play", fields: [
                "generation": .integer(1), "device": .string(target.name), "host": .string(target.host),
                "source": .string(served.url.absoluteString), "nativeMedia": .boolean(true),
                "contentType": .string(media.contentType), "title": .string("Nest Player silent connectivity check"),
                "startTimeout": .number(15),
                "traceMediaProtocol": .boolean(true),
            ])
            var played = false
            for await event in events where event.generation == 1 {
                if event.event == "diagnostic", let message = event.message {
                    try? FileHandle.standardError.write(contentsOf: Data(("Receiver " + message + "\n").utf8))
                }
                if event.event == "failed" { throw CastBackendError.commandFailed(event.message ?? "Cast probe failed") }
                if event.event == "state", event.state == "PLAYING" { played = true }
                if event.event == "completed" { break }
            }
            guard played else { throw CastBackendError.commandFailed("Cast never reported PLAYING") }
            let after = try await backend.request("status", fields: ["generation": .integer(1)])
            guard after.volume == before.volume else { throw CastBackendError.commandFailed("Speaker volume changed during the probe") }
        }
    }

    private static func makeSilentFixture(in root: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
        let url = root.appending(path: "silence.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            buffer.floatChannelData![channel].update(repeating: 0, count: Int(buffer.frameLength))
        }
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        try output.write(from: buffer)
        return url
    }

    private static func finish(ok: Bool, detail: String) -> Never {
        let data = try! JSONSerialization.data(withJSONObject: ["ok": ok, "detail": detail])
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        exit(ok ? 0 : 1)
    }
}
#endif
