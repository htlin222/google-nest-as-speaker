import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(PlayerModel.self) private var model
    @State private var showImporter = false
    @State private var importingFolder = false
    @State private var showSMB = false
    @State private var chooseFolderAfterSMB = false
    @State private var showRemote = false
    @State private var linkText = ""
    @State private var isSeeking = false
    @State private var scrubPosition = 0.0
    @State private var renamingTrack: Track?
    @State private var renameText = ""
    @State private var confirmClear = false
    @State private var playlistNaming: PlaylistNaming?
    @State private var playlistNameText = ""
    @State private var confirmDeletePlaylist = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    TextField("YouTube or Bilibili link", text: $linkText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if model.addLinks(from: linkText) { linkText = "" } }
                    HStack {
                        Button("Paste & Play", systemImage: "doc.on.clipboard") { pasteLink() }
                        Spacer()
                        Button("Add") {
                            if model.addLinks(from: linkText, playFirst: false) { linkText = "" }
                        }.disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .buttonStyle(.borderless)
                    if model.isScanningFolder {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Scanning folder…").font(.caption)
                            Spacer()
                            Button("Cancel") { model.cancelFolderScan() }.buttonStyle(.borderless)
                        }
                    }
                }.padding(12)
                Divider()
                playlistHeader
                List(selection: $model.selectedTrackIDs) {
                    ForEach(model.playlist) { track in
                        TrackRow(track: track, isPlaying: model.activeTrack?.id == track.id && model.phase.isActive)
                            .tag(track.id)
                    }
                    .onMove(perform: model.moveTracks)
                }
                .contextMenu(forSelectionType: Track.ID.self) { ids in
                    trackMenu(for: ids)
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first, let track = model.playlist.first(where: { $0.id == id }) {
                        model.play(track: track)
                    }
                }
                .onDeleteCommand { model.removeSelectedTracks() }
                .overlay {
                    if model.playlist.isEmpty {
                        ContentUnavailableView(
                            "No tracks",
                            systemImage: "music.note.list",
                            description: Text("Add audio or video files to start a Cast playlist")
                        )
                    }
                }

                Divider()
                HStack {
                    Menu {
                        Button("Add Files…") { importingFolder = false; showImporter = true }
                        Button("Add Folder…") { importingFolder = true; showImporter = true }
                        Button("Connect SMB Folder…") { showSMB = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("Add files, a folder, or an SMB share")

                    Button { model.removeSelectedTracks() } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(model.selectedTrackIDs.isEmpty)
                    .help("Remove selected tracks (Delete)")

                    Menu {
                        Button("Name (A → Z)") { model.sortPlaylist(ascending: true) }
                        Button("Name (Z → A)") { model.sortPlaylist(ascending: false) }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(model.playlist.count < 2)
                    .help("Sort playlist by name")

                    Spacer()

                    Button("Clear") { confirmClear = true }
                        .disabled(model.playlist.isEmpty)
                        .confirmationDialog("Remove all \(model.playlist.count) tracks?", isPresented: $confirmClear) {
                            Button("Clear Playlist", role: .destructive) { model.clearPlaylist() }
                        }
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            playerPanel
        }
        .toolbar { deviceToolbar }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importingFolder ? [.folder] : [.audio, .audiovisualContent],
            allowsMultipleSelection: !importingFolder
        ) { result in
            switch result {
            case .success(let urls):
                if importingFolder, let folder = urls.first { model.addFolder(folder) }
                else { model.importSecurityScoped(urls) }
            case .failure(let error): model.statusDetail = error.localizedDescription
            }
        }
        .sheet(item: $model.authenticationRequest) { request in WebsiteLoginSheet(request: request) }
        .sheet(isPresented: $showSMB, onDismiss: {
            if chooseFolderAfterSMB {
                chooseFolderAfterSMB = false
                importingFolder = true
                showImporter = true
            }
        }) { SMBConnectionSheet { chooseFolderAfterSMB = true } }
        .sheet(isPresented: $showRemote) { PhoneRemoteSheet() }
        .alert(playlistNaming?.title ?? "", isPresented: Binding(get: { playlistNaming != nil }, set: { if !$0 { playlistNaming = nil } })) {
            TextField("Playlist name", text: $playlistNameText)
            Button(playlistNaming == .create ? "Create" : "Rename") {
                switch playlistNaming {
                case .create: model.createPlaylist(named: playlistNameText)
                case .rename(let id): model.renamePlaylist(id, to: playlistNameText)
                case nil: break
                }
                playlistNaming = nil
            }
            Button("Cancel", role: .cancel) { playlistNaming = nil }
        }
        .confirmationDialog(
            "Delete playlist “\(model.currentPlaylist.name)” and its \(model.playlist.count) tracks?",
            isPresented: $confirmDeletePlaylist
        ) {
            Button("Delete Playlist", role: .destructive) { model.deletePlaylist(model.currentPlaylist.id) }
        } message: {
            Text("The audio files themselves are not deleted.")
        }
        .alert("Rename Track", isPresented: Binding(get: { renamingTrack != nil }, set: { if !$0 { renamingTrack = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let track = renamingTrack { model.renameTrack(track.id, to: renameText) }
                renamingTrack = nil
            }
            Button("Cancel", role: .cancel) { renamingTrack = nil }
        } message: {
            Text("Leave empty to restore the original name.")
        }
        .onPasteCommand(of: [.plainText, .url]) { _ in pasteLink() }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                if url.isFileURL, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { model.addFolder(url) }
                else if url.isFileURL { model.importSecurityScoped([url]) }
                else { model.addTracks([url]) }
            }
            return !urls.isEmpty
        } isTargeted: { model.isDropTarget = $0 }
        .overlay {
            if model.isDropTarget {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 4, dash: [9]))
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.currentTime) { _, newValue in
            if !isSeeking { scrubPosition = newValue }
        }
        .onChange(of: model.remoteSnapshot, initial: true) { _, _ in model.publishRemoteState() }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--phone-remote") { showRemote = true }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var playerPanel: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 12)

            mediaDisplay

            VStack(spacing: 7) {
                Text(model.displayedTrack?.title ?? "Nest Player")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .contextMenu {
                        if let track = model.displayedTrack, model.playlist.contains(where: { $0.id == track.id }) {
                            trackMenu(for: [track.id])
                        }
                    }
                if let timer = model.sleepTimer {
                    Label(
                        model.sleepRemaining.map { "Stops in \(TimeText.format($0.rounded(.up)))" }
                            ?? "Stops after \(timer == .endOfTrack ? "this track" : "timer")",
                        systemImage: "moon.zzz.fill"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
                }
                Text(model.statusDetail)
                    .font(.callout)
                    .foregroundStyle(model.phase.isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            progressSection
            transportControls
            volumeSection

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var mediaDisplay: some View {
        if model.showsVideo {
            PlayerLayerView(player: model.localPlayer)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 640, maxHeight: 340)
                .background(.black, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.28), radius: 24, y: 14)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.indigo.opacity(0.95), .purple.opacity(0.75), .pink.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .purple.opacity(0.25), radius: 28, y: 16)
                Image(systemName: model.phase == .playing ? "waveform" : "hifispeaker.2.fill")
                    .font(.system(size: 88, weight: .light))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(width: 250, height: 250)
            .accessibilityHidden(true)
        }
    }

    private var progressSection: some View {
        VStack(spacing: 5) {
            Slider(
                value: $scrubPosition,
                in: 0...max(model.duration, 1),
                onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing, model.duration > 0 { model.seek(to: scrubPosition) }
                }
            )
            .disabled(model.duration <= 0 || !model.phase.isActive)

            HStack {
                Text(TimeText.format(isSeeking ? scrubPosition : model.currentTime))
                Spacer()
                Text(model.duration > 0 ? TimeText.format(model.duration) : "–:––")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 560)
    }

    private var transportControls: some View {
        HStack(spacing: 24) {
            Button { model.stop() } label: {
                Image(systemName: "stop.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .font(.title2)
            .disabled(!model.canStop)
            .help("Stop")

            Button { model.previousTrack() } label: {
                Image(systemName: "backward.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .font(.title2)
            .disabled(!model.canGoPrevious)
            .help("Previous track")

            Button { model.togglePlayPause() } label: {
                Image(systemName: model.phase == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background(.tint, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.canTogglePlayback)
            .help(model.phase == .playing ? "Pause" : "Play")

            Button { model.nextTrack() } label: {
                Image(systemName: "forward.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .font(.title2)
            .disabled(!model.canGoNext)
            .help("Next track")

            Button { model.repeatMode = model.repeatMode.next } label: {
                Image(systemName: model.repeatMode.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(model.repeatMode != .off ? Color.white : Color.primary)
                    .background(
                        model.repeatMode != .off ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
            .buttonStyle(.borderless)
            .font(.title2)
            .help("\(model.repeatMode.label) — click to change")
            .accessibilityLabel(model.repeatMode.label)

            Menu {
                ForEach(SleepTimerChoice.presets, id: \.self) { minutes in
                    Button("\(minutes) minutes") { model.setSleepTimer(.minutes(minutes)) }
                }
                Button("End of current track") { model.setSleepTimer(.endOfTrack) }
                if model.sleepTimer != nil {
                    Divider()
                    Button("Turn Off Sleep Timer") { model.setSleepTimer(nil) }
                }
            } label: {
                Image(systemName: model.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(model.sleepTimer != nil ? Color.white : Color.primary)
                    .background(
                        model.sleepTimer != nil ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.sleepTimer.map { "Sleep timer: \($0.label) — fades out over the last 30 s" } ?? "Sleep timer")
            .accessibilityLabel("Sleep timer")
        }
    }

    private var volumeSection: some View {
        VStack(spacing: 12) {
            Toggle(
                "Mac audio",
                isOn: Binding(
                    get: { model.localAudioEnabled },
                    set: { model.setLocalAudioEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .help("Off by default. Turn on to hear audio from both this Mac and the Cast speaker.")

            HStack(spacing: 10) {
                Image(systemName: model.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                Slider(
                    value: Binding(
                        get: { model.volume },
                        set: { model.setVolume($0) }
                    ),
                    in: 0...100
                )
                Image(systemName: "hifispeaker.2.fill")
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 340)
        .disabled(model.selectedDevice == nil)
        .accessibilityLabel("Audio output and Cast speaker volume")
    }

    @ToolbarContentBuilder
    private var deviceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(
                "Speaker",
                selection: Binding(
                    get: { model.selectedDeviceName },
                    set: { model.selectDevice($0) }
                )
            ) {
                if model.devices.isEmpty {
                    Text("No speakers").tag(model.selectedDeviceName)
                } else {
                    ForEach(model.devices) { device in
                        Text(device.name).tag(device.name)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 130)

            Button { model.refreshDevices() } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
            .help("Find Cast speakers")

            Button { showRemote = true } label: { Label("Phone Remote", systemImage: "qrcode") }
                .help("Control from iPhone over your local network")

            Menu {
                Button("Connect SMB Folder…") { showSMB = true }
                Button("Forget Website Browser Access") { model.forgetWebsiteSessions() }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private func pasteLink() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            model.statusDetail = "Copy a YouTube or Bilibili video link first."
            return
        }
        if model.addLinks(from: text) { linkText = "" }
    }
}

private enum PlaylistNaming: Equatable {
    case create
    case rename(Playlist.ID)

    var title: String { self == .create ? "New Playlist" : "Rename Playlist" }
}

private extension ContentView {
    var playlistHeader: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(model.library.playlists) { playlist in
                    Button { model.selectPlaylist(playlist.id) } label: {
                        if playlist.id == model.currentPlaylist.id {
                            Label("\(playlist.name) (\(playlist.tracks.count))", systemImage: "checkmark")
                        } else {
                            Text("\(playlist.name) (\(playlist.tracks.count))")
                        }
                    }
                }
                Divider()
                Button("New Playlist…") {
                    playlistNameText = ""
                    playlistNaming = .create
                }
                Button("Rename “\(model.currentPlaylist.name)”…") {
                    playlistNameText = model.currentPlaylist.name
                    playlistNaming = .rename(model.currentPlaylist.id)
                }
                Button("Delete “\(model.currentPlaylist.name)”…", role: .destructive) { confirmDeletePlaylist = true }
                    .disabled(model.library.playlists.count < 2)
            } label: {
                Label(model.currentPlaylist.name, systemImage: "music.note.list")
                    .font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch, create, rename, or delete playlists")

            Spacer()

            Button {
                playlistNameText = ""
                playlistNaming = .create
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(.borderless)
            .help("New playlist")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    func trackMenu(for ids: Set<Track.ID>) -> some View {
        let tracks = model.playlist.filter { ids.contains($0.id) }
        if tracks.count == 1, let track = tracks.first {
            Button("Play") { model.play(track: track) }
            Button("Rename…") {
                renameText = track.title
                renamingTrack = track
            }
            if let site = MediaLinks.site(for: track.url) {
                Button("Sign in to \(site)…") { model.showWebsiteLogin(for: track) }
            }
            Divider()
        }
        let others = model.library.playlists.filter { $0.id != model.currentPlaylist.id }
        if !tracks.isEmpty, !others.isEmpty {
            Menu("Add to Playlist") {
                ForEach(others) { playlist in
                    Button(playlist.name) { model.copyTracks(ids, to: playlist.id) }
                }
            }
        }
        if !tracks.isEmpty {
            Button(tracks.count == 1 ? "Remove" : "Remove \(tracks.count) Tracks", role: .destructive) {
                model.removeTracks(ids)
            }
        }
    }
}

private struct TrackRow: View {
    let track: Track
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "music.note")
                .frame(width: 24)
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(track.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private extension PlayerPhase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
