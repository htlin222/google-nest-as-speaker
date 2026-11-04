import Foundation
import Testing
@testable import NestPlayer

@Test func decodesDeviceDiscoveryPayload() throws {
    let json = #"{"devices":[{"name":"客廳","model":"Google Nest Mini","host":"192.0.2.10","port":8009,"type":"audio"}]}"#
    let result = try JSONDecoder().decode(DeviceList.self, from: Data(json.utf8))
    #expect(result.devices.count == 1)
    #expect(result.devices[0].name == "客廳")
    #expect(result.devices[0].isAudioTarget)
}

@Test func decodesPlaybackStatus() throws {
    let json = #"{"device":"客廳","player":"PLAYING","title":"Song","currentTime":12.5,"duration":60.0,"volume":35,"muted":false}"#
    let status = try JSONDecoder().decode(CastStatus.self, from: Data(json.utf8))
    #expect(status.player == "PLAYING")
    #expect(status.currentTime == 12.5)
    #expect(status.volume == 35)
}

@Test func formatsPlaybackTime() {
    #expect(TimeText.format(0) == "0:00")
    #expect(TimeText.format(65.9) == "1:05")
    #expect(TimeText.format(3_661) == "1:01:01")
}

@Test func identifiesVideoTracks() {
    #expect(Track(url: URL(fileURLWithPath: "/tmp/movie.mp4")).isVideo)
    #expect(!Track(url: URL(fileURLWithPath: "/tmp/song.mp3")).isVideo)
}

@Test func parsesSharedWebsiteLinksAndKeepsSingleVideoIdentity() {
    let links = MediaLinks.parse("Watch https://youtu.be/abc_123?si=tracking then https://www.youtube.com/watch?v=abc_123&list=playlist and https://www.bilibili.com/video/BV1test?p=2&share_source=copy")
    #expect(links.count == 2)
    #expect(links[0].absoluteString == "https://www.youtube.com/watch?v=abc_123")
    #expect(links[1].absoluteString == "https://www.bilibili.com/video/BV1test?p=2")
    #expect(MediaLinks.parse("https://youtube.com.evil.example/watch?v=abc").isEmpty)
    #expect(MediaLinks.parse("https://www.youtube.com/playlist?list=abc").isEmpty)
}

@Test func smbAddressesUseFinderCredentialsOnly() {
    #expect(SMBAddress.parse("smb://nas/media") != nil)
    #expect(SMBAddress.parse("smb://user:password@nas/media") == nil)
    #expect(SMBAddress.parse("https://nas/media") == nil)
}

@Test func playlistRecordsPreserveOnlineAndOfflineNetworkTracks() throws {
    let tracks = [Track(url: URL(string: "https://youtu.be/example")!), Track(url: URL(fileURLWithPath: "/Volumes/Offline/music.mp3"))]
    let restored = try JSONDecoder().decode([Track].self, from: JSONEncoder().encode(tracks))
    #expect(restored == tracks)
    #expect(restored[0].source.hasPrefix("https://"))
    #expect(restored[1].source == "/Volumes/Offline/music.mp3")
}

@Test func folderScanSkipsHiddenAndSymlinkFilesAndSortsNaturally() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["track10.mp3", "track2.mp3", ".hidden.mp3", "notes.txt", "nested/movie.mp4"] {
        try Data("fixture".utf8).write(to: root.appending(path: name))
    }
    try FileManager.default.createSymbolicLink(at: root.appending(path: "linked.mp3"), withDestinationURL: root.appending(path: "track2.mp3"))
    let result = try MediaFolderScanner.scan(root)
    #expect(result.urls.map(\.lastPathComponent) == ["movie.mp4", "track2.mp3", "track10.mp3"])
    #expect(!result.truncated)
}

@Test func terminatesAnEntirePlaybackProcessTree() async throws {
    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: "/bin/sh")
    parent.arguments = ["-c", "/bin/sleep 30 & wait"]
    try parent.run()
    try await Task.sleep(for: .milliseconds(150))

    let descendants = ProcessTreeSupervisor.descendantPIDs(of: parent.processIdentifier)
    #expect(!descendants.isEmpty)
    ProcessTreeSupervisor.terminate(parent)
    parent.waitUntilExit()
    try await Task.sleep(for: .milliseconds(100))

    #expect(!parent.isRunning)
    for pid in descendants {
        #expect(kill(pid, 0) != 0)
    }
}

private func track(_ name: String) -> Track { Track(url: URL(fileURLWithPath: "/tmp/\(name).mp3")) }

@Test func sortsPlaylistByNameLikeFinder() {
    let tracks = ["b song", "Track 10", "A song", "Track 2"].map(track)
    #expect(PlaylistEditor.sortedByName(tracks).map(\.title) == ["A song", "b song", "Track 2", "Track 10"])
    #expect(PlaylistEditor.sortedByName(tracks, ascending: false).map(\.title) == ["Track 10", "Track 2", "b song", "A song"])
}

@Test func removesSeveralTracksAndSelectsTheFollowingOne() {
    let tracks = ["a", "b", "c", "d"].map(track)
    let result = PlaylistEditor.removing([tracks[1].id, tracks[2].id], from: tracks)
    #expect(result.playlist.map(\.title) == ["a", "d"])
    #expect(result.nextSelection == tracks[3].id)
    let tail = PlaylistEditor.removing([tracks[3].id], from: tracks)
    #expect(tail.nextSelection == tracks[2].id)
    #expect(PlaylistEditor.removing(Set(tracks.map(\.id)), from: tracks).nextSelection == nil)
}

@Test func renamesTrackAndEmptyNameRestoresOriginal() throws {
    var tracks = [track("original")]
    tracks[0].resolvedTitle = "Website Title"
    tracks = PlaylistEditor.renaming(tracks[0].id, to: "  My Name ", in: tracks)
    #expect(tracks[0].title == "My Name")
    let decoded = try JSONDecoder().decode([Track].self, from: JSONEncoder().encode(tracks))
    #expect(decoded[0].title == "My Name")
    tracks = PlaylistEditor.renaming(tracks[0].id, to: " ", in: tracks)
    #expect(tracks[0].title == "Website Title")
}

@Test func decodesTracksSavedBeforeCustomTitles() throws {
    let json = #"[{"id":"00000000-0000-4000-8000-000000000001","url":"file:///tmp/old.mp3"}]"#
    let tracks = try JSONDecoder().decode([Track].self, from: Data(json.utf8))
    #expect(tracks[0].customTitle == nil)
    #expect(tracks[0].title == "old")
}

@Test func nextTrackWrapsOnlyWhenRepeatingPlaylist() {
    let tracks = ["a", "b", "c"].map(track)
    #expect(PlaylistEditor.nextID(after: tracks[0].id, in: tracks, wrapping: false) == tracks[1].id)
    #expect(PlaylistEditor.nextID(after: tracks[2].id, in: tracks, wrapping: false) == nil)
    #expect(PlaylistEditor.nextID(after: tracks[2].id, in: tracks, wrapping: true) == tracks[0].id)
    #expect(PlaylistEditor.nextID(after: UUID(), in: tracks, wrapping: true) == nil)
}

@Test func repeatModeCyclesAndControlsAutoAdvance() {
    #expect(RepeatMode.off.next == .all && RepeatMode.all.next == .one && RepeatMode.one.next == .off)
    let tracks = ["a", "b"].map(track)
    #expect(PlaylistEditor.autoAdvanceID(after: tracks[1].id, in: tracks, mode: .off) == nil)
    #expect(PlaylistEditor.autoAdvanceID(after: tracks[1].id, in: tracks, mode: .all) == tracks[0].id)
    #expect(PlaylistEditor.autoAdvanceID(after: tracks[0].id, in: tracks, mode: .one) == tracks[0].id)
}
