import Darwin
import Foundation

enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }
}

struct BackendMessage: Codable, Sendable {
    let event: String
    let id: String?
    let ok: Bool?
    let error: String?
    let message: String?
    let generation: Int?
    let devices: [CastDevice]?
    let state: String?
    let source: String?
    let device: String?
    let currentTime: Double?
    let duration: Double?
    let volume: Int?
    let reason: String?
    let cached: Bool?
    let title: String?
    let site: String?
    let localAudioURL: String?
    let localVideoURL: String?
    let remoteURL: String?
    let pairingCode: String?
    let action: String?
    let value: String?
    let pythonVersion: String?
    let opensslVersion: String?
    let expatVersion: String?
}

enum CastBackendError: LocalizedError {
    case missingUV
    case missingHelper
    case serviceStopped(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingUV: "uv was not found. Install uv with Homebrew first."
        case .missingHelper: "The Nest Player service could not be found."
        case .serviceStopped(let detail): detail.isEmpty ? "The Nest Player service stopped." : detail
        case .commandFailed(let message): message.isEmpty ? "The Cast command failed." : message
        }
    }
}

final class CastBackend: @unchecked Sendable {
    typealias EventHandler = @Sendable (BackendMessage) -> Void
    private typealias Continuation = CheckedContinuation<BackendMessage, any Error>

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let diagnostics: FileHandle
    private let lock = NSLock()
    private var pending: [String: Continuation] = [:]
    private var eventHandler: EventHandler?
    private var diagnosticTail = ""
    private var shuttingDown = false

    init() throws {
        let process = Process()
        let storeHelper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/NestCastService.app/Contents/MacOS/nest-service")
        let communityHelper = Bundle.main.url(
            forResource: "nest-service",
            withExtension: nil,
            subdirectory: "nest-service"
        )
        if let bundled = [storeHelper, communityHelper].compactMap({ $0 })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            process.executableURL = bundled
            process.arguments = ["--json", "service"]
        } else {
            #if APP_STORE
            // A Store app must remain self-contained; never invoke Homebrew/uv.
            throw CastBackendError.missingHelper
            #else
            guard let uv = Self.findExecutable(
                environmentKey: "UV",
                candidates: ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            ) else { throw CastBackendError.missingUV }
            guard let root = Self.findRepositoryRoot() else {
                throw CastBackendError.missingHelper
            }
            let helper = root.appending(path: ".agents/skills/google-nest-speaker/scripts/nest_speaker.py")
            guard FileManager.default.fileExists(atPath: helper.path) else {
                throw CastBackendError.missingHelper
            }
            process.executableURL = uv
            process.arguments = [
                "run", "--locked", "--project", root.path,
                "python", helper.path, "--json", "service",
            ]
            process.currentDirectoryURL = root
            #endif
        }

        var environment = ProcessInfo.processInfo.environment
        #if APP_STORE
        let standardPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = standardPath
        #else
        let standardPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [environment["PATH"], standardPath]
            .compactMap { $0 }
            .joined(separator: ":")
        #endif
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let diagnosticPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = diagnosticPipe
        try process.run()

        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        diagnostics = diagnosticPipe.fileHandleForReading
        startReaders()
    }

    func setEventHandler(_ handler: @escaping EventHandler) {
        lock.withLock { eventHandler = handler }
    }

    func request(_ command: String, fields: [String: JSONValue] = [:]) async throws -> BackendMessage {
        let id = UUID().uuidString
        var payload = fields
        payload["id"] = .string(id)
        payload["command"] = .string(command)
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard process.isRunning, !shuttingDown else {
                let detail = diagnosticTail
                lock.unlock()
                continuation.resume(throwing: CastBackendError.serviceStopped(detail))
                return
            }
            pending[id] = continuation
            do {
                try input.write(contentsOf: data)
                lock.unlock()
            } catch {
                pending.removeValue(forKey: id)
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    func shutdown() {
        let shouldShutdown = lock.withLock { () -> Bool in
            if shuttingDown { return false }
            shuttingDown = true
            return true
        }
        guard shouldShutdown else { return }
        if process.isRunning {
            let payload = #"{"id":"shutdown","command":"shutdown"}"# + "\n"
            try? input.write(contentsOf: Data(payload.utf8))
            let deadline = Date().addingTimeInterval(1.5)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
        }
        failPending(CastBackendError.serviceStopped("Nest Player closed."))
    }

    private func startReaders() {
        Task.detached(priority: .userInitiated) { [weak self] in self?.readMessages() }
        Task.detached(priority: .utility) { [weak self] in self?.readDiagnostics() }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let detail = self.lock.withLock { self.diagnosticTail }
            self.failPending(
                CastBackendError.serviceStopped(
                    detail.isEmpty ? "Nest Player service exited with code \(process.terminationStatus)." : detail
                )
            )
        }
    }

    private func readMessages() {
        var pendingData = Data()
        while true {
            let chunk = output.availableData
            if chunk.isEmpty { break }
            pendingData.append(chunk)
            while let newline = pendingData.firstIndex(of: 0x0A) {
                let line = pendingData[..<newline]
                pendingData.removeSubrange(...newline)
                route(Data(line))
            }
        }
    }

    private func readDiagnostics() {
        while true {
            let data = diagnostics.availableData
            if data.isEmpty { return }
            let text = String(decoding: data, as: UTF8.self)
            lock.withLock { diagnosticTail = String((diagnosticTail + text).suffix(4_000)) }
        }
    }

    private func route(_ data: Data) {
        guard let message = try? JSONDecoder().decode(BackendMessage.self, from: data) else {
            let line = String(decoding: data, as: UTF8.self)
            lock.withLock { diagnosticTail = String((diagnosticTail + line + "\n").suffix(4_000)) }
            return
        }
        if message.event == "response", let id = message.id {
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            if message.ok == false {
                continuation?.resume(throwing: CastBackendError.commandFailed(message.error ?? "Cast command failed"))
            } else {
                continuation?.resume(returning: message)
            }
            return
        }
        let handler = lock.withLock { eventHandler }
        handler?(message)
    }

    private func failPending(_ error: Error) {
        let continuations = lock.withLock { () -> [Continuation] in
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private static func findExecutable(environmentKey: String, candidates: [String]) -> URL? {
        let configured = ProcessInfo.processInfo.environment[environmentKey]
        return ([configured].compactMap { $0 } + candidates)
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func findRepositoryRoot() -> URL? {
        if let configured = ProcessInfo.processInfo.environment["NEST_PLAYER_REPO_ROOT"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: candidate.appending(path: "nest-speaker").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

enum ProcessTreeSupervisor {
    static func terminate(_ process: Process) {
        let descendants = descendantPIDs(of: process.processIdentifier)
        for pid in descendants.reversed() { Darwin.kill(pid, SIGTERM) }
        process.terminate()
    }

    static func descendantPIDs(of parent: pid_t) -> [pid_t] {
        let lookup = Process()
        let output = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        lookup.arguments = ["-P", String(parent)]
        lookup.standardOutput = output
        lookup.standardError = FileHandle.nullDevice
        do {
            try lookup.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            lookup.waitUntilExit()
            let children = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0) }
            return children + children.flatMap(descendantPIDs(of:))
        } catch {
            return []
        }
    }
}
