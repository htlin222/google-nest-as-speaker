import AppKit
import SwiftUI

@main
@MainActor
struct NestPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: PlayerModel

    init() {
        #if DEBUG && APP_STORE
        let arguments = ProcessInfo.processInfo.arguments
        let verifyLAN = arguments.contains("--service-network-smoke")
        let playSilence = arguments.contains("--cast-silence-smoke")
        if arguments.contains("--service-smoke") || verifyLAN || playSilence {
            let expected = arguments.firstIndex(of: "--expected-speaker").flatMap { index in
                arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            }
            BackendSmoke.start(verifyLAN: verifyLAN, expectedSpeaker: expected, playSilence: playSilence)
            _model = State(initialValue: PlayerModel(preview: true))
            return
        }
        #endif
        _model = State(initialValue: PlayerModel())
    }

    var body: some Scene {
        WindowGroup("Nest Player") {
            ContentView()
                .environment(model)
                .task {
                    appDelegate.model = model
                    model.refreshDevices()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 680)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: PlayerModel?

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}
