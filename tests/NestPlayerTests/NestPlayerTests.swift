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
