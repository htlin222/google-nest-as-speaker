#if DEBUG && APP_STORE
import AVFoundation
import Foundation

/// Runs only on explicit developer invocation. Never discovers or controls a speaker.
enum BackendSmoke {
    static func start() {
        Task.detached {
            // A stopped service must fail this probe instead of leaving CI hanging.
            Task.detached {
                try? await Task.sleep(for: .seconds(20))
                finish(ok: false, detail: "Service probe timed out")
            }
            do {
                try await probe()
                finish(ok: true, detail: "Sandboxed service, phone HTTP, native audio export/cache and byte ranges passed")
            } catch {
                finish(ok: false, detail: error.localizedDescription)
            }
        }
    }

    private static func probe() async throws {
        let backend = try CastBackend()
        defer { backend.shutdown() }
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
        let source = try makeSilentFixture(in: root)
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
    }

    private static func makeSilentFixture(in root: URL) throws -> URL {
        let url = root.appending(path: "silence.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2205)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
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
