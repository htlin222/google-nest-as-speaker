import AppKit
import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlayerModel {
    private static let playlistDefaultsKey = "playlistPaths"
    private static let devicesDefaultsKey = "cachedCastDevices"
    private static let playlistRecordsKey = "playlistRecordsV2"
    private static let libraryKey = "playlistLibraryV3"
    private static let alarmsKey = "alarmsV1"

    var library = PlaylistLibrary(playlists: [])
    /// Tracks of the playlist shown in the sidebar; playback always follows it.
    var playlist: [Track] {
        get { library.current.tracks }
        set { library.current.tracks = newValue }
    }
    var currentPlaylist: Playlist { library.current }
    /// The single "current" track used by play/next/previous.
    var selectedTrackID: Track.ID? {
        didSet {
            if let selectedTrackID, selectedTrackIDs != [selectedTrackID] { selectedTrackIDs = [selectedTrackID] }
            if selectedTrackID == nil, !selectedTrackIDs.isEmpty { selectedTrackIDs = [] }
            if selectedTrackID != oldValue, !hasSession {
                configureLocalPlayer(for: selectedTrack)
            }
        }
    }
    /// List selection; may hold several tracks for bulk removal.
    var selectedTrackIDs: Set<Track.ID> = [] {
        didSet {
            if selectedTrackIDs.count == 1, let id = selectedTrackIDs.first, id != selectedTrackID { selectedTrackID = id }
        }
    }
    var devices: [CastDevice] = []
    var selectedDeviceName = UserDefaults.standard.string(forKey: "selectedDevice") ?? "客廳"
    var phase: PlayerPhase = .idle
    var currentTime = 0.0
    var duration = 0.0
    var volume = 50.0
    var localAudioEnabled = false
    var repeatMode: RepeatMode {
        get { library.current.repeatMode }
        set {
            library.current.repeatMode = newValue
            savePlaylist()
        }
    }
    var statusDetail = "Starting Cast service…"
    private(set) var sleepTimer: SleepTimerChoice?
    var alarms: [Alarm] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(alarms) { UserDefaults.standard.set(data, forKey: Self.alarmsKey) }
        }
    }
    /// Seconds until the sleep timer stops playback; nil while unknown (e.g. end of track not playing).
    private(set) var sleepRemaining: Double?
    var isDropTarget = false
    var isDiscovering = false
    var localPlayer: AVPlayer?
    var onlineHasVideo = false
    var authenticationRequest: WebsiteLoginRequest?
    var isScanningFolder = false
    var remoteURL: URL?
    var pairingCode = ""
    var smbAddress = UserDefaults.standard.string(forKey: "smbAddress") ?? "smb://"
    private(set) var hasSession = false
    private(set) var activeTrack: Track?

    @ObservationIgnored private let backend: CastBackend?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var localAudioPlayer: AVPlayer?
    @ObservationIgnored private var onlineAudioURL: URL?
    @ObservationIgnored private var browserSessions: [String: String] = [:]
    @ObservationIgnored private var folderTask: Task<FolderScan, any Error>?
    @ObservationIgnored private var fileAccess: FileAccessStore?
    /// Seconds to seek to once the given playback generation reports PLAYING.
    @ObservationIgnored private var pendingResume: (generation: Int, seconds: Double)?
    @ObservationIgnored private var lastResumeSave = Date.distantPast
    @ObservationIgnored private var sleepDeadline: Date?
    @ObservationIgnored private var alarmTask: Task<Void, Never>?
    @ObservationIgnored private var lastAlarmFire: [Alarm.ID: Date] = [:]
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// Speaker volume before the fade began; restored when the timer ends or is cancelled.
    @ObservationIgnored private var fadeOriginalVolume: Double?
    #if APP_STORE
    @ObservationIgnored private let nativePreparer = NativeMediaPreparer()
    @ObservationIgnored private var nativeMediaServer: NativeMediaServer?
    #endif

    #if DEBUG
    @ObservationIgnored private var isDocumentationPreview = false
    /// Documentation renderer only: never creates a backend or writes preferences.
    init(preview: Bool) {
        backend = nil
        isDocumentationPreview = true
        let samples: [(String, String)] = [
            ("file:///Demo/Midnight%20Coast.flac", "Midnight Coast — Live Session"),
            ("https://www.youtube.com/watch?v=documentation_demo", "Sunday Focus — Studio Session"),
            ("https://www.bilibili.com/video/BVdemo/", "設計的日常 — 聲音與空間"),
            ("file:///Volumes/StudioNAS/Field%20Notes.m4a", "Field Notes — NAS Collection"),
            ("file:///Demo/Piano%20in%20the%20Rain.flac", "Piano in the Rain"),
            ("file:///Demo/Night%20Train.mp4", "Night Train — Film Study"),
        ]
        library = PlaylistLibrary(playlists: [Playlist(name: "Focus"), Playlist(name: "Bedtime"), Playlist(name: "Kids Stories")])
        playlist = samples.enumerated().map { index, sample in
            var track = Track(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!, url: URL(string: sample.0)!)
            track.resolvedTitle = sample.1
            return track
        }
        devices = [CastDevice(name: "Studio Nest", model: "Google Nest Mini", host: "192.0.2.10", port: 8009, type: "audio")]
        selectedDeviceName = "Studio Nest"
        hasSession = true
        selectedTrackID = playlist.first?.id
        activeTrack = playlist.first
        phase = .playing
        currentTime = 204
        duration = 1240
        volume = 38
        statusDetail = "Casting to Studio Nest · Demo data"
        smbAddress = "smb://studio-nas/music"
        remoteURL = URL(string: "http://192.0.2.10:8989/?token=nonfunctional-documentation-demo")
        pairingCode = "000000"
    }
    #endif

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
        fileAccess = FileAccessStore()
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

        // Keep offline network files and website links so reconnecting can restore playback.
        if let data = UserDefaults.standard.data(forKey: Self.libraryKey),
           let saved = try? JSONDecoder().decode(PlaylistLibrary.self, from: data) {
            library = saved
        } else {
            let legacyTracks: [Track]
            if let data = UserDefaults.standard.data(forKey: Self.playlistRecordsKey),
               let tracks = try? JSONDecoder().decode([Track].self, from: data) {
                legacyTracks = tracks
            } else {
                let savedPaths = UserDefaults.standard.stringArray(forKey: Self.playlistDefaultsKey) ?? []
                legacyTracks = savedPaths.map { Track(url: URL(fileURLWithPath: $0)) }
            }
            let legacyRepeat = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeatMode") ?? "") ?? .off
            library = .migrating(legacyTracks: legacyTracks, repeatMode: legacyRepeat)
            // V2 stays untouched so a downgrade still finds the old playlist.
            savePlaylist()
        }
        selectedTrackID = resumeSelection()
        configureLocalPlayer(for: selectedTrack)
        if let data = UserDefaults.standard.data(forKey: Self.alarmsKey),
           let saved = try? JSONDecoder().decode([Alarm].self, from: data) {
            alarms = saved
        }
        alarmTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkAlarms(now: Date())
                try? await Task.sleep(for: .seconds(15))
            }
        }

        createdBackend?.setEventHandler { [weak self] message in
            Task { @MainActor in self?.consume(message) }
        }
    }

    var selectedTrack: Track? {
        guard let selectedTrackID else { return playlist.first }
        return playlist.first { $0.id == selectedTrackID }
    }

    var displayedTrack: Track? { activeTrack ?? selectedTrack }
    var showsVideo: Bool { displayedTrack?.url.isFileURL == true ? displayedTrack?.isVideo == true : onlineHasVideo }

    var selectedDevice: CastDevice? {
        devices.first { $0.name == selectedDeviceName }
    }

    var canPlay: Bool {
        #if DEBUG
        if isDocumentationPreview { return selectedTrack != nil && selectedDevice != nil }
        #endif
        return selectedTrack != nil && selectedDevice != nil && backend != nil
    }
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
        guard let selectedTrackID else { return false }
        return PlaylistEditor.nextID(after: selectedTrackID, in: playlist, wrapping: repeatMode != .off) != nil
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
        var seen = Set(playlist.map(\.source))
        let additions = urls.compactMap { value -> Track? in
            guard let url = value.isFileURL ? value.standardizedFileURL : MediaLinks.normalize(value) else { return nil }
            let track = Track(url: url)
            guard seen.insert(track.source).inserted else { return nil }
            return track
        }
        playlist.append(contentsOf: additions)
        if selectedTrackID == nil { selectedTrackID = playlist.first?.id }
        if !additions.isEmpty {
            statusDetail = "Added \(additions.count) track\(additions.count == 1 ? "" : "s")"
            savePlaylist()
        }
    }

    @discardableResult
    func addLinks(from text: String, playFirst: Bool = true) -> Bool {
        let urls = MediaLinks.parse(text)
        guard let first = urls.first else {
            statusDetail = "Paste a YouTube or Bilibili video link (share text is accepted)."
            return false
        }
        addTracks(urls)
        if let track = playlist.first(where: { $0.url == first }) {
            selectedTrackID = track.id
            if playFirst { requestPlayback(of: track) }
        }
        return true
    }

    func addFolder(_ folder: URL) {
        folderTask?.cancel()
        let readableFolder: URL
        do {
            try fileAccess?.authorize(folder, isDirectory: true)
            readableFolder = try fileAccess?.readableURL(for: folder) ?? folder
        } catch {
            statusDetail = error.localizedDescription
            return
        }
        isScanningFolder = true
        statusDetail = "Scanning \(folder.lastPathComponent)…"
        let scan = Task.detached(priority: .utility) { try MediaFolderScanner.scan(readableFolder) }
        folderTask = scan
        Task {
            defer {
                if !scan.isCancelled { isScanningFolder = false }
            }
            do {
                let result = try await scan.value
                guard !scan.isCancelled else { return }
                let before = playlist.count
                addTracks(result.urls)
                statusDetail = "Added \(playlist.count - before) files from \(folder.lastPathComponent)" + (result.truncated ? " (10,000-file scan limit)" : "")
            } catch {
                guard !scan.isCancelled else { return }
                statusDetail = "Could not read folder. If it is on SMB, connect the share in Finder and retry."
            }
        }
    }

    func cancelFolderScan() {
        folderTask?.cancel()
        isScanningFolder = false
        statusDetail = "Folder scan cancelled"
    }

    func connectSMB() {
        guard let url = SMBAddress.parse(smbAddress) else {
            statusDetail = "Use smb://server/share. Enter your password only in the Finder login dialog."
            return
        }
        UserDefaults.standard.set(url.absoluteString, forKey: "smbAddress")
        NSWorkspace.shared.open(url)
        statusDetail = "Connect in Finder, then choose Add Folder and select the mounted share."
    }

    func showWebsiteLogin(for track: Track? = nil) {
        guard let track = track ?? selectedTrack, MediaLinks.site(for: track.url) != nil else { return }
        authenticationRequest = WebsiteLoginRequest(track: track, message: "Sign in on the website, then let Nest Player use the selected browser session.")
    }

    func openLogin(in browser: BrowserSession, for request: WebsiteLoginRequest) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else { return }
        NSWorkspace.shared.open([request.track.url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    func retryLogin(_ request: WebsiteLoginRequest, browser: BrowserSession, remember: Bool) {
        if remember { browserSessions[request.site] = browser.id }
        authenticationRequest = nil
        requestPlayback(of: request.track, browserOverride: browser.id)
    }

    func forgetWebsiteSessions() {
        browserSessions.removeAll()
        if let backend { Task { _ = try? await backend.request("forgetWebsiteSessions") } }
        statusDetail = "Browser-session access cleared for future playback."
    }

    func importSecurityScoped(_ urls: [URL]) {
        for url in urls {
            do {
                try fileAccess?.authorize(url)
                addTracks([url])
            } catch { statusDetail = error.localizedDescription }
        }
    }

    func removeSelectedTracks() {
        var ids = selectedTrackIDs
        if ids.isEmpty, let selectedTrackID { ids = [selectedTrackID] }
        removeTracks(ids)
    }

    func removeTracks(_ ids: Set<Track.ID>) {
        guard !ids.isEmpty else { return }
        let before = playlist.count
        let result = PlaylistEditor.removing(ids, from: playlist)
        playlist = result.playlist
        selectedTrackID = result.nextSelection
        let removed = before - playlist.count
        if removed > 0 { statusDetail = "Removed \(removed) track\(removed == 1 ? "" : "s")" }
        savePlaylist()
    }

    func renameTrack(_ id: Track.ID, to name: String) {
        playlist = PlaylistEditor.renaming(id, to: name, in: playlist)
        if let activeTrack, activeTrack.id == id { self.activeTrack = playlist.first { $0.id == id } }
        savePlaylist()
    }

    func sortPlaylist(ascending: Bool) {
        playlist = PlaylistEditor.sortedByName(playlist, ascending: ascending)
        savePlaylist()
    }

    // MARK: Sleep timer

    func setSleepTimer(_ choice: SleepTimerChoice?) {
        restoreFadedVolume()
        clearSleepTimer()
        guard let choice else {
            statusDetail = "Sleep timer off"
            return
        }
        sleepTimer = choice
        if case .minutes(let minutes) = choice { sleepDeadline = Date().addingTimeInterval(Double(minutes) * 60) }
        statusDetail = "Sleep timer: \(choice.label)"
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sleepTick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        sleepTick()
    }

    private func sleepTick() {
        guard let sleepTimer else { return }
        switch sleepTimer {
        case .minutes: sleepRemaining = sleepDeadline.map { max($0.timeIntervalSinceNow, 0) }
        case .endOfTrack: sleepRemaining = hasSession && duration > 0 ? max(duration - currentTime, 0) : nil
        }
        guard let remaining = sleepRemaining else { return }
        if case .minutes = sleepTimer, remaining <= 0 {
            finishSleepTimer()
            return
        }
        guard hasSession, phase == .playing,
              let level = SleepFade.volume(original: fadeOriginalVolume ?? volume, remaining: remaining)
        else { return }
        if fadeOriginalVolume == nil { fadeOriginalVolume = volume }
        if level != volume { applyVolume(level) }
    }

    /// Stops playback, then puts the speaker back at its pre-fade volume.
    private func finishSleepTimer() {
        let original = fadeOriginalVolume
        fadeOriginalVolume = nil
        clearSleepTimer()
        if hasSession { stop() }
        if let original { applyVolume(original) }
        statusDetail = "Sleep timer ended · playback stopped"
    }

    private func restoreFadedVolume() {
        guard let original = fadeOriginalVolume else { return }
        fadeOriginalVolume = nil
        applyVolume(original)
    }

    private func clearSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = nil
        sleepDeadline = nil
        sleepRemaining = nil
    }

    // MARK: Alarms

    func addAlarm() {
        alarms.append(Alarm(playlistID: library.currentID))
    }

    func deleteAlarm(_ id: Alarm.ID) {
        alarms.removeAll { $0.id == id }
    }

    /// Soonest upcoming alarm across all enabled ones, for the toolbar and sheet.
    func nextAlarm(after now: Date = Date()) -> (alarm: Alarm, date: Date)? {
        alarms.compactMap { alarm in AlarmSchedule.nextFire(alarm, after: now).map { (alarm, $0) } }
            .min { $0.1 < $1.1 }
    }

    private func checkAlarms(now: Date) {
        for alarm in alarms {
            guard let due = AlarmSchedule.dueFire(alarm, now: now, lastFired: lastAlarmFire[alarm.id]) else { continue }
            lastAlarmFire[alarm.id] = due
            fire(alarm)
        }
    }

    /// Starts the alarm's playlist from its first track; never interrupts playback or changes volume.
    private func fire(_ alarm: Alarm) {
        let time = String(format: "%02d:%02d", alarm.hour, alarm.minute)
        guard !hasSession else {
            statusDetail = "Alarm \(time) skipped · already playing"
            return
        }
        guard library.playlists.contains(where: { $0.id == alarm.playlistID }) else {
            statusDetail = "Alarm \(time) skipped · its playlist was deleted"
            return
        }
        selectPlaylist(alarm.playlistID)
        guard let first = playlist.first else {
            statusDetail = "Alarm \(time) skipped · \(currentPlaylist.name) is empty"
            return
        }
        guard canPlay else {
            statusDetail = "Alarm \(time) skipped · no Cast speaker available"
            return
        }
        selectedTrackID = first.id
        requestPlayback(of: first)
        statusDetail = "Alarm \(time) · playing \(currentPlaylist.name)"
    }

    // MARK: Playlists

    /// Switching stops playback; the position is kept so switching back resumes it.
    func selectPlaylist(_ id: Playlist.ID) {
        guard id != library.currentID else { return }
        if hasSession { stop() }
        library.select(id)
        selectedTrackID = resumeSelection()
        savePlaylist()
        statusDetail = "Playlist: \(currentPlaylist.name)"
    }

    func createPlaylist(named name: String) {
        if hasSession { stop() }
        library.create(named: name)
        selectedTrackID = nil
        savePlaylist()
        statusDetail = "Created playlist \(currentPlaylist.name)"
    }

    func renamePlaylist(_ id: Playlist.ID, to name: String) {
        library.rename(id, to: name)
        savePlaylist()
    }

    func deletePlaylist(_ id: Playlist.ID) {
        guard library.playlists.count > 1 else { return }
        let wasCurrent = id == library.currentID
        if wasCurrent, hasSession { stop() }
        library.delete(id)
        if wasCurrent { selectedTrackID = resumeSelection() }
        savePlaylist()
    }

    func copyTracks(_ ids: Set<Track.ID>, to playlistID: Playlist.ID) {
        let tracks = playlist.filter { ids.contains($0.id) }
        let added = library.copy(tracks, to: playlistID)
        let name = library.playlists.first { $0.id == playlistID }?.name ?? "playlist"
        statusDetail = added == 0 ? "Already in \(name)" : "Added \(added) track\(added == 1 ? "" : "s") to \(name)"
        savePlaylist()
    }

    private func resumeSelection() -> Track.ID? {
        let current = library.current
        if let id = current.resumeTrackID, current.tracks.contains(where: { $0.id == id }) { return id }
        return current.tracks.first?.id
    }

    /// Remembers where the current playlist is; persisted at most every 5 s while playing.
    private func recordResume(_ trackID: Track.ID, at seconds: Double, persist: Bool = false) {
        guard playlist.contains(where: { $0.id == trackID }) else { return }
        library.current.resumeTrackID = trackID
        library.current.resumePosition = seconds.isFinite ? max(seconds, 0) : 0
        if persist || Date().timeIntervalSince(lastResumeSave) >= 5 { savePlaylist() }
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
        requestPlayback(of: track, startAt: currentPlaylist.resumeStart(for: track.id))
    }

    func play(track: Track) {
        selectedTrackID = track.id
        requestPlayback(of: track, startAt: currentPlaylist.resumeStart(for: track.id))
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
              let nextID = PlaylistEditor.nextID(after: selectedTrackID, in: playlist, wrapping: repeatMode != .off),
              let track = playlist.first(where: { $0.id == nextID })
        else { return }
        self.selectedTrackID = track.id
        requestPlayback(of: track)
    }

    func pause() {
        if let activeTrack { recordResume(activeTrack.id, at: currentTime, persist: true) }
        sendControl("pause", targetPhase: .paused, detail: "Playback paused")
    }
    func resume() { sendControl("resume", targetPhase: .playing, detail: "Casting to \(selectedDeviceName)") }

    func stop() {
        if let activeTrack { recordResume(activeTrack.id, at: currentTime, persist: true) }
        pendingResume = nil
        authenticationRequest = nil
        generation += 1
        let stoppedGeneration = generation
        transitionTask?.cancel()
        #if APP_STORE
        nativeMediaServer?.close()
        nativeMediaServer = nil
        #endif
        hasSession = false
        activeTrack = nil
        phase = .idle
        statusDetail = "Playback stopped"
        currentTime = 0
        localPlayer?.pause()
        localAudioPlayer?.pause()
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
        localAudioPlayer?.seek(to: CMTime(seconds: bounded, preferredTimescale: 600))
        sendControl("seek", fields: ["seconds": .number(bounded)])
    }

    /// User volume change. During a sleep fade it wins: the timer is cancelled and the new level kept.
    func setVolume(_ newValue: Double) {
        if fadeOriginalVolume != nil {
            fadeOriginalVolume = nil
            clearSleepTimer()
            statusDetail = "Sleep timer cancelled"
        }
        applyVolume(newValue)
    }

    private func applyVolume(_ newValue: Double) {
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
        localPlayer?.isMuted = onlineAudioURL != nil || !enabled
        if enabled, localAudioPlayer == nil, let onlineAudioURL {
            let player = AVPlayer(url: onlineAudioURL)
            player.allowsExternalPlayback = false
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
            localAudioPlayer = player
        }
        localAudioPlayer?.isMuted = !enabled
        if enabled && phase == .playing { localAudioPlayer?.play() }
        else { localAudioPlayer?.pause() }
    }

    func refreshStatus() {}

    func shutdown() {
        sleepTask?.cancel()
        alarmTask?.cancel()
        if let activeTrack { recordResume(activeTrack.id, at: currentTime) }
        savePlaylist()
        generation += 1
        transitionTask?.cancel()
        volumeTask?.cancel()
        folderTask?.cancel()
        localPlayer?.pause()
        localAudioPlayer?.pause()
        backend?.shutdown()
        #if APP_STORE
        nativeMediaServer?.close()
        nativeMediaServer = nil
        #endif
        fileAccess?.close()
    }

    private func requestPlayback(of track: Track, startAt: Double = 0, browserOverride: String? = nil) {
        guard let backend, let castDevice = selectedDevice else { return }
        authenticationRequest = nil
        generation += 1
        let requestGeneration = generation
        pendingResume = startAt > 0 ? (requestGeneration, startAt) : nil
        recordResume(track.id, at: startAt, persist: true)
        let device = castDevice.name
        let host = castDevice.host
        transitionTask?.cancel()
        #if APP_STORE
        nativeMediaServer?.close()
        nativeMediaServer = nil
        #endif
        hasSession = true
        activeTrack = track
        currentTime = 0
        duration = 0
        configureLocalPlayer(for: track)
        phase = .connecting
        statusDetail = "Opening \(track.title)"

        transitionTask = Task {
            do {
                var source = track.url.isFileURL
                    ? try (fileAccess?.readableURL(for: track.url) ?? track.url).path
                    : track.source
                #if APP_STORE
                var nativeType: String?
                if track.url.isFileURL {
                    _ = try await backend.request("stop", fields: ["generation": .integer(requestGeneration)])
                    try Task.checkCancellation()
                    phase = .transcoding
                    statusDetail = "Preparing audio from \(track.title)"
                    let prepared = try await nativePreparer.prepare(URL(fileURLWithPath: source))
                    try Task.checkCancellation()
                    let served = try await NativeMediaServer.serve(file: prepared.file, contentType: prepared.contentType)
                    guard generation == requestGeneration, !Task.isCancelled else {
                        served.server.close()
                        return
                    }
                    nativeMediaServer = served.server
                    source = served.url.absoluteString
                    nativeType = prepared.contentType
                    phase = .connecting
                    statusDetail = prepared.cached ? "Using cached audio" : "Media ready"
                }
                #endif
                var fields: [String: JSONValue] = [
                    "generation": .integer(requestGeneration),
                    "device": .string(device),
                    "host": .string(host),
                    "source": .string(source),
                    "title": .string(track.title),
                    "startTimeout": .number(20),
                ]
                #if APP_STORE
                if let nativeType {
                    fields["nativeMedia"] = .boolean(true)
                    fields["contentType"] = .string(nativeType)
                }
                #endif
                if let browser = browserOverride ?? browserSessions[MediaLinks.site(for: track.url) ?? ""] {
                    fields["browser"] = .string(browser)
                }
                _ = try await backend.request("play", fields: fields)
            } catch {
                guard generation == requestGeneration, !Task.isCancelled else { return }
                #if APP_STORE
                nativeMediaServer?.close()
                nativeMediaServer = nil
                #endif
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
                if command == "pause" { localAudioPlayer?.pause() }
                if command == "resume", localAudioEnabled { localAudioPlayer?.play() }
            } catch {
                guard generation == requestGeneration else { return }
                fail(error)
            }
        }
    }

    private func consume(_ event: BackendMessage) {
        if event.event == "remoteCommand" {
            handleRemoteCommand(event.action ?? "", value: event.value ?? "")
            return
        }
        if event.event == "serviceReady" {
            if devices.isEmpty && !hasSession { statusDetail = "Cast service ready" }
            return
        }
        guard event.generation == generation else { return }
        switch event.event {
        case "resolving":
            phase = .connecting
            statusDetail = "Loading \(event.site ?? "video")…"
        case "onlineReady":
            if let title = event.title, var track = activeTrack {
                track.resolvedTitle = title
                track.customTitle = playlist.first(where: { $0.id == track.id })?.customTitle
                activeTrack = track
                if let index = playlist.firstIndex(where: { $0.id == track.id }) { playlist[index] = track }
                savePlaylist()
            }
            configureOnlinePlayers(audio: event.localAudioURL, video: event.localVideoURL)
            updateTimes(event)
        case "authenticationRequired":
            let track = activeTrack
            hasSession = false
            activeTrack = nil
            localPlayer?.pause()
            localAudioPlayer?.pause()
            phase = .idle
            statusDetail = "Sign in to \(event.site ?? "the website") on the Mac to continue."
            if let track {
                authenticationRequest = WebsiteLoginRequest(track: track, message: event.message ?? statusDetail)
            }
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
                if localAudioEnabled { localAudioPlayer?.play() }
                phase = .playing
                statusDetail = "Casting to \(selectedDeviceName)"
                applyPendingResume()
            case "PAUSED": localPlayer?.pause(); localAudioPlayer?.pause(); phase = .paused
            case "BUFFERING": phase = .connecting
            default: break
            }
        case "progress":
            updateTimes(event)
            synchronizeLocalPlayer(to: event.currentTime ?? currentTime)
            applyPendingResume()
            if pendingResume == nil, let activeTrack { recordResume(activeTrack.id, at: currentTime) }
        case "completed":
            #if APP_STORE
            nativeMediaServer?.close()
            nativeMediaServer = nil
            #endif
            let finished = activeTrack
            hasSession = false
            activeTrack = nil
            localPlayer?.pause()
            localAudioPlayer?.pause()
            phase = .idle
            currentTime = 0
            statusDetail = "Finished \(finished?.title ?? "track")"
            if let finished {
                recordResume(finished.id, at: 0, persist: true)
                if sleepTimer == .endOfTrack { finishSleepTimer() } else { playNext(after: finished) }
            }
        case "failed":
            #if APP_STORE
            nativeMediaServer?.close()
            nativeMediaServer = nil
            #endif
            hasSession = false
            activeTrack = nil
            localPlayer?.pause()
            localAudioPlayer?.pause()
            phase = .failed(event.message ?? "Cast playback failed")
            statusDetail = event.message ?? "Cast playback failed"
        default: break
        }
    }

    /// Seeks once Cast is playing and knows the duration; seeking earlier would clamp to 0.
    private func applyPendingResume() {
        guard let resume = pendingResume, resume.generation == generation,
              phase == .playing, duration > 0
        else { return }
        pendingResume = nil
        if resume.seconds < duration - 5 {
            seek(to: resume.seconds)
            statusDetail = "Resumed at \(TimeText.format(resume.seconds))"
        }
    }

    private func updateTimes(_ event: BackendMessage) {
        if let value = event.currentTime { currentTime = value }
        if let value = event.duration { duration = value }
    }

    private func playNext(after track: Track) {
        guard let nextID = PlaylistEditor.autoAdvanceID(after: track.id, in: playlist, mode: repeatMode),
              let next = playlist.first(where: { $0.id == nextID })
        else { return }
        selectedTrackID = next.id
        requestPlayback(of: next)
    }

    private func savePlaylist() {
        #if DEBUG
        if isDocumentationPreview { return }
        #endif
        lastResumeSave = Date()
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: Self.libraryKey)
        }
    }

    private func configureLocalPlayer(for track: Track?) {
        localPlayer?.pause()
        localAudioPlayer?.pause()
        localAudioPlayer = nil
        onlineAudioURL = nil
        onlineHasVideo = false
        guard let track, track.url.isFileURL else { localPlayer = nil; return }
        guard let url = try? fileAccess?.readableURL(for: track.url) ?? track.url else {
            localPlayer = nil
            return
        }
        let player = AVPlayer(url: url)
        player.isMuted = !localAudioEnabled
        player.allowsExternalPlayback = false
        localPlayer = player
    }

    private func synchronizeLocalPlayer(to remoteTime: Double, force: Bool = false) {
        guard let localPlayer, remoteTime.isFinite, remoteTime >= 0 else { return }
        let localTime = localPlayer.currentTime().seconds
        if force || !localTime.isFinite || abs(localTime - remoteTime) > 0.75 {
            localPlayer.seek(
                to: CMTime(seconds: remoteTime, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
            )
        }
        if let localAudioPlayer {
            let audioTime = localAudioPlayer.currentTime().seconds
            if force || !audioTime.isFinite || abs(audioTime - remoteTime) > 0.75 {
                localAudioPlayer.seek(to: CMTime(seconds: remoteTime, preferredTimescale: 600))
            }
        }
    }

    private func configureOnlinePlayers(audio: String?, video: String?) {
        localPlayer?.pause()
        localAudioPlayer?.pause()
        localAudioPlayer = nil
        onlineHasVideo = video != nil
        onlineAudioURL = video == nil ? nil : audio.flatMap(URL.init(string:))
        if let source = video ?? audio, let url = URL(string: source) {
            localPlayer = AVPlayer(url: url)
            localPlayer?.allowsExternalPlayback = false
            localPlayer?.isMuted = video != nil || !localAudioEnabled
        }
        if localAudioEnabled, let onlineAudioURL {
            localAudioPlayer = AVPlayer(url: onlineAudioURL)
            localAudioPlayer?.allowsExternalPlayback = false
        }
    }

    /// Unpairs every phone, including Home Screen remotes; they must enter the new code.
    func resetRemotePairing() {
        guard let backend else { return }
        Task {
            do {
                let result = try await backend.request("remoteReset")
                remoteURL = result.remoteURL.flatMap(URL.init(string:))
                pairingCode = result.pairingCode ?? ""
                statusDetail = "Phone pairing reset · paired phones must reconnect"
            } catch { statusDetail = "Phone remote: \(error.localizedDescription)" }
        }
    }

    func loadRemoteInfo() {
        guard let backend else { return }
        Task {
            do {
                let result = try await backend.request("remoteInfo")
                remoteURL = result.remoteURL.flatMap(URL.init(string:))
                pairingCode = result.pairingCode ?? ""
                publishRemoteState()
            } catch { statusDetail = "Phone remote: \(error.localizedDescription)" }
        }
    }

    var remoteSnapshot: String {
        let tracks = playlist.map { RemoteTrack(id: $0.id.uuidString, title: $0.title, selected: $0.id == selectedTrackID) }
        let state = RemoteState(
            title: displayedTrack?.title ?? "Ready to play", detail: statusDetail,
            speaker: selectedDeviceName, playing: phase == .playing,
            position: currentTime.isFinite ? currentTime : 0,
            duration: duration.isFinite ? duration : 0, volume: volume,
            macAudio: localAudioEnabled, tracks: tracks,
            playlists: library.playlists.map {
                RemotePlaylist(id: $0.id.uuidString, name: $0.name, current: $0.id == library.currentID)
            },
            repeat: repeatMode.rawValue,
            sleep: sleepTimer.map { RemoteSleep(choice: $0.remoteValue, remaining: sleepRemaining.map { $0.rounded(.up) }) }
        )
        return (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func publishRemoteState() {
        guard let backend else { return }
        let state = remoteSnapshot
        Task { _ = try? await backend.request("remoteState", fields: ["state": .string(state)]) }
    }

    private func handleRemoteCommand(_ action: String, value: String) {
        switch action {
        case "toggle": togglePlayPause()
        case "stop": stop()
        case "previous": previousTrack()
        case "next": nextTrack()
        case "seek": if let seconds = Double(value), seconds.isFinite { seek(to: seconds) }
        case "volume": if let level = Double(value), level.isFinite { setVolume(level) }
        case "macAudio": setLocalAudioEnabled(value == "1")
        case "addLink": addLinks(from: value)
        case "playTrack":
            if let id = UUID(uuidString: value), let track = playlist.first(where: { $0.id == id }) { play(track: track) }
        case "selectPlaylist":
            if let id = UUID(uuidString: value) { selectPlaylist(id) }
        case "repeat":
            if let mode = RepeatMode(rawValue: value) { repeatMode = mode }
        case "sleep":
            setSleepTimer(SleepTimerChoice(remoteValue: value))
        default: break
        }
    }

    private func fail(_ error: Error) {
        phase = .failed(error.localizedDescription)
        statusDetail = error.localizedDescription
    }
}

private struct RemoteTrack: Encodable {
    let id: String
    let title: String
    let selected: Bool
}

private struct RemoteState: Encodable {
    let title: String
    let detail: String
    let speaker: String
    let playing: Bool
    let position: Double
    let duration: Double
    let volume: Double
    let macAudio: Bool
    let tracks: [RemoteTrack]
    let playlists: [RemotePlaylist]
    let `repeat`: String
    let sleep: RemoteSleep?
}

private struct RemotePlaylist: Encodable {
    let id: String
    let name: String
    let current: Bool
}

private struct RemoteSleep: Encodable {
    let choice: String
    let remaining: Double?
}
