import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlayerModel {
    private static let playlistDefaultsKey = "playlistPaths"
    private static let devicesDefaultsKey = "cachedCastDevices"

    var playlist: [Track] = []
    var selectedTrackID: Track.ID? {
        didSet {
            if selectedTrackID != oldValue, !hasSession {
                configureLocalPlayer(for: selectedTrack)
            }
        }
    }
    var devices: [CastDevice] = []
    var selectedDeviceName = UserDefaults.standard.string(forKey: "selectedDevice") ?? "客廳"
    var phase: PlayerPhase = .idle
    var currentTime = 0.0
    var duration = 0.0
    var volume = 50.0
    var localAudioEnabled = false
    var statusDetail = "Starting Cast service…"
    var isDropTarget = false
    var isDiscovering = false
    var localPlayer: AVPlayer?
    private(set) var hasSession = false
    private(set) var activeTrack: Track?

    @ObservationIgnored private let backend: CastBackend?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init() {
        let createdBackend: CastBackend?
        let startupError: Error?
        do {
            createdBackend = try CastBackend()
            startupError = nil
        } catch {
            createdBackend = nil
            startupError = error
        }
        backend = createdBackend
        if let startupError {
            phase = .failed(startupError.localizedDescription)
            statusDetail = startupError.localizedDescription
        }

        if let cached = UserDefaults.standard.data(forKey: Self.devicesDefaultsKey),
           let decoded = try? JSONDecoder().decode([CastDevice].self, from: cached) {
            devices = decoded.filter(\.isAudioTarget)
            if !devices.contains(where: { $0.name == selectedDeviceName }), let first = devices.first {
                selectedDeviceName = first.name
            }
            if !devices.isEmpty { statusDetail = "Ready to cast to \(selectedDeviceName)" }
        }

        let savedPaths = UserDefaults.standard.stringArray(forKey: Self.playlistDefaultsKey) ?? []
        playlist = savedPaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Track(url: $0) }
        selectedTrackID = playlist.first?.id
        configureLocalPlayer(for: selectedTrack)

        createdBackend?.setEventHandler { [weak self] message in
            Task { @MainActor in self?.consume(message) }
        }
    }

    var selectedTrack: Track? {
        guard let selectedTrackID else { return playlist.first }
        return playlist.first { $0.id == selectedTrackID }
    }

    var displayedTrack: Track? { activeTrack ?? selectedTrack }

    var selectedDevice: CastDevice? {
        devices.first { $0.name == selectedDeviceName }
    }

    var canPlay: Bool { selectedTrack != nil && selectedDevice != nil && backend != nil }
    var canTogglePlayback: Bool {
        canPlay && phase != .connecting && phase != .transcoding && phase != .discovering
    }
    var canStop: Bool { hasSession }

    var canGoPrevious: Bool {
        guard let selectedTrackID,
              let index = playlist.firstIndex(where: { $0.id == selectedTrackID })
        else { return false }
        return index > 0 || currentTime > 3
    }

    var canGoNext: Bool {
        guard let selectedTrackID,
              let index = playlist.firstIndex(where: { $0.id == selectedTrackID })
        else { return false }
        return playlist.indices.contains(index + 1)
    }

    func refreshDevices() {
        guard let backend, !isDiscovering else { return }
        isDiscovering = true
        if !hasSession && devices.isEmpty {
            phase = .discovering
            statusDetail = "Finding Google Cast speakers…"
        }
        let requestedDevice = selectedDeviceName
        Task {
            defer { isDiscovering = false }
            do {
                let response = try await backend.request("list", fields: [
                    "device": .string(requestedDevice),
                    "timeout": .number(5),
                ])
                devices = (response.devices ?? []).filter(\.isAudioTarget)
                if let encoded = try? JSONEncoder().encode(devices) {
                    UserDefaults.standard.set(encoded, forKey: Self.devicesDefaultsKey)
                }
                if !devices.contains(where: { $0.name == selectedDeviceName }),
                   let preferred = devices.first(where: { $0.type == "audio" }) ?? devices.first {
                    selectedDeviceName = preferred.name
                }
                if !hasSession {
                    phase = .idle
                    statusDetail = devices.isEmpty ? "No Cast speakers found" : "Ready to cast to \(selectedDeviceName)"
                }
            } catch {
                if !hasSession { fail(error) }
                else { statusDetail = "Speaker refresh failed: \(error.localizedDescription)" }
            }
        }
    }

    func selectDevice(_ name: String) {
        selectedDeviceName = name
        UserDefaults.standard.set(name, forKey: "selectedDevice")
    }

    func addTracks(_ urls: [URL]) {
        let existingPaths = Set(playlist.map { $0.url.standardizedFileURL.path })
        let additions = urls
            .filter(\.isFileURL)
            .filter { !existingPaths.contains($0.standardizedFileURL.path) }
            .map { Track(url: $0.standardizedFileURL) }
        playlist.append(contentsOf: additions)
        if selectedTrackID == nil { selectedTrackID = playlist.first?.id }
        if !additions.isEmpty {
            statusDetail = "Added \(additions.count) track\(additions.count == 1 ? "" : "s")"
            savePlaylist()
        }
    }

    func importSecurityScoped(_ urls: [URL]) {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            addTracks([url])
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
    }

    func removeSelectedTrack() {
        guard let selectedTrackID,
              let index = playlist.firstIndex(where: { $0.id == selectedTrackID })
        else { return }
        playlist.remove(at: index)
        self.selectedTrackID = playlist.indices.contains(index) ? playlist[index].id : playlist.last?.id
        savePlaylist()
    }

    func clearPlaylist() {
        playlist.removeAll()
        selectedTrackID = nil
        savePlaylist()
    }

    func moveTracks(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.sorted().map { playlist[$0] }
        let remaining = playlist.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertion = min(max(destination - removedBeforeDestination, 0), remaining.count)
        playlist = Array(remaining[..<insertion]) + moving + Array(remaining[insertion...])
        savePlaylist()
    }

    func togglePlayPause() {
        switch phase {
        case .playing: pause()
        case .paused: resume()
        case .connecting, .transcoding, .discovering: break
        default: playSelected()
        }
    }

    func playSelected() {
        guard let track = selectedTrack else { return }
        requestPlayback(of: track)
    }

    func play(track: Track) {
        selectedTrackID = track.id
        requestPlayback(of: track)
    }

    func previousTrack() {
        if currentTime > 3 { seek(to: 0); return }
        guard let selectedTrackID,
              let index = playlist.firstIndex(where: { $0.id == selectedTrackID }), index > 0
        else { return }
        let track = playlist[index - 1]
        self.selectedTrackID = track.id
        requestPlayback(of: track)
    }

    func nextTrack() {
        guard let selectedTrackID,
              let index = playlist.firstIndex(where: { $0.id == selectedTrackID }),
              playlist.indices.contains(index + 1)
        else { return }
        let track = playlist[index + 1]
        self.selectedTrackID = track.id
        requestPlayback(of: track)
    }

    func pause() { sendControl("pause", targetPhase: .paused, detail: "Playback paused") }
    func resume() { sendControl("resume", targetPhase: .playing, detail: "Casting to \(selectedDeviceName)") }

    func stop() {
        generation += 1
        let stoppedGeneration = generation
        transitionTask?.cancel()
        hasSession = false
        activeTrack = nil
        phase = .idle
        statusDetail = "Playback stopped"
        currentTime = 0
        localPlayer?.pause()
        localPlayer?.seek(to: .zero)
        configureLocalPlayer(for: selectedTrack)
        guard let backend else { return }
        Task {
            do {
                _ = try await backend.request("stop", fields: ["generation": .integer(stoppedGeneration)])
            } catch {
                guard generation == stoppedGeneration else { return }
                statusDetail = error.localizedDescription
            }
        }
    }

    func seek(to seconds: Double) {
        let bounded = min(max(seconds, 0), duration)
        currentTime = bounded
        localPlayer?.seek(to: CMTime(seconds: bounded, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        sendControl("seek", fields: ["seconds": .number(bounded)])
    }

    func setVolume(_ newValue: Double) {
        volume = min(max(newValue, 0), 100)
        volumeTask?.cancel()
        let requested = Int(volume.rounded())
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let backend else { return }
            do {
                let response = try await backend.request("volume", fields: [
                    "device": .string(selectedDeviceName),
                    "level": .integer(requested),
                ])
                if let actual = response.volume { volume = Double(actual) }
            } catch { statusDetail = error.localizedDescription }
        }
    }

    func setLocalAudioEnabled(_ enabled: Bool) {
        localAudioEnabled = enabled
        localPlayer?.isMuted = !enabled
    }

    func refreshStatus() {}

    func shutdown() {
        generation += 1
        transitionTask?.cancel()
        volumeTask?.cancel()
        localPlayer?.pause()
        backend?.shutdown()
    }

    private func requestPlayback(of track: Track) {
        guard let backend, let castDevice = selectedDevice else { return }
        generation += 1
        let requestGeneration = generation
        let device = castDevice.name
        let host = castDevice.host
        transitionTask?.cancel()
        hasSession = true
        activeTrack = track
        currentTime = 0
        duration = 0
        configureLocalPlayer(for: track)
        phase = .connecting
        statusDetail = "Opening \(track.title)"

        transitionTask = Task {
            do {
                _ = try await backend.request("play", fields: [
                    "generation": .integer(requestGeneration),
                    "device": .string(device),
                    "host": .string(host),
                    "source": .string(track.url.path),
                    "title": .string(track.title),
                    "startTimeout": .number(20),
                ])
            } catch {
                guard generation == requestGeneration, !Task.isCancelled else { return }
                hasSession = false
                activeTrack = nil
                fail(error)
            }
        }
    }

    private func sendControl(
        _ command: String,
        fields: [String: JSONValue] = [:],
        targetPhase: PlayerPhase? = nil,
        detail: String? = nil
    ) {
        guard let backend, hasSession else { return }
        let requestGeneration = generation
        var payload = fields
        payload["generation"] = .integer(requestGeneration)
        Task {
            do {
                _ = try await backend.request(command, fields: payload)
                guard generation == requestGeneration, hasSession else { return }
                if let targetPhase { phase = targetPhase }
                if let detail { statusDetail = detail }
                if command == "pause" { localPlayer?.pause() }
                if command == "resume" { localPlayer?.play() }
            } catch {
                guard generation == requestGeneration else { return }
                fail(error)
            }
        }
    }

    private func consume(_ event: BackendMessage) {
        if event.event == "serviceReady" {
            if devices.isEmpty && !hasSession { statusDetail = "Cast service ready" }
            return
        }
        guard event.generation == generation else { return }
        switch event.event {
        case "transcoding":
            phase = .transcoding
            statusDetail = "Preparing \(event.source ?? "audio")"
        case "remuxing":
            phase = .transcoding
            statusDetail = "Extracting audio from \(event.source ?? "media")"
        case "ready":
            phase = .connecting
            statusDetail = event.cached == true ? "Using cached audio" : "Media ready"
        case "casting":
            phase = .connecting
            statusDetail = "Connecting to \(event.device ?? selectedDeviceName)"
        case "state":
            updateTimes(event)
            switch event.state {
            case "PLAYING":
                synchronizeLocalPlayer(to: event.currentTime ?? currentTime, force: true)
                localPlayer?.play()
                phase = .playing
                statusDetail = "Casting to \(selectedDeviceName)"
            case "PAUSED": localPlayer?.pause(); phase = .paused
            case "BUFFERING": phase = .connecting
            default: break
            }
        case "progress":
            updateTimes(event)
            synchronizeLocalPlayer(to: event.currentTime ?? currentTime)
        case "completed":
            let finished = activeTrack
            hasSession = false
            activeTrack = nil
            localPlayer?.pause()
            phase = .idle
            currentTime = 0
            statusDetail = "Finished \(finished?.title ?? "track")"
            if let finished { playNext(after: finished) }
        case "failed":
            hasSession = false
            activeTrack = nil
            localPlayer?.pause()
            phase = .failed(event.message ?? "Cast playback failed")
            statusDetail = event.message ?? "Cast playback failed"
        default: break
        }
    }

    private func updateTimes(_ event: BackendMessage) {
        if let value = event.currentTime { currentTime = value }
        if let value = event.duration { duration = value }
    }

    private func playNext(after track: Track) {
        guard let index = playlist.firstIndex(where: { $0.id == track.id }),
              playlist.indices.contains(index + 1)
        else { return }
        let next = playlist[index + 1]
        selectedTrackID = next.id
        requestPlayback(of: next)
    }

    private func savePlaylist() {
        UserDefaults.standard.set(playlist.map(\.url.path), forKey: Self.playlistDefaultsKey)
    }

    private func configureLocalPlayer(for track: Track?) {
        localPlayer?.pause()
        guard let track else { localPlayer = nil; return }
        let player = AVPlayer(url: track.url)
        player.isMuted = !localAudioEnabled
        player.allowsExternalPlayback = false
        localPlayer = player
    }

    private func synchronizeLocalPlayer(to remoteTime: Double, force: Bool = false) {
        guard let localPlayer, remoteTime.isFinite, remoteTime >= 0 else { return }
        let localTime = localPlayer.currentTime().seconds
        guard force || !localTime.isFinite || abs(localTime - remoteTime) > 0.75 else { return }
        localPlayer.seek(
            to: CMTime(seconds: remoteTime, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
        )
    }

    private func fail(_ error: Error) {
        phase = .failed(error.localizedDescription)
        statusDetail = error.localizedDescription
    }
}
