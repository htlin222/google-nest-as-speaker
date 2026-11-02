import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(PlayerModel.self) private var model
    @State private var showImporter = false
    @State private var isSeeking = false
    @State private var scrubPosition = 0.0

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedTrackID) {
                    ForEach(model.playlist) { track in
                        TrackRow(track: track, isPlaying: model.selectedTrackID == track.id && model.phase.isActive)
                            .tag(track.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.play(track: track) }
                    }
                    .onMove(perform: model.moveTracks)
                }
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
                    Button { showImporter = true } label: {
                        Label("Add", systemImage: "plus")
                    }
            .help("Add audio or video files")

                    Button { model.removeSelectedTrack() } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(model.selectedTrackID == nil)
                    .help("Remove selected track")

                    Spacer()

                    Button("Clear") { model.clearPlaylist() }
                        .disabled(model.playlist.isEmpty)
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
            allowedContentTypes: [.audio, .audiovisualContent],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): model.importSecurityScoped(urls)
            case .failure(let error): model.statusDetail = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addTracks(urls)
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
        if model.displayedTrack?.isVideo == true {
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
