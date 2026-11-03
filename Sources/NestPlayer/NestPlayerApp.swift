import AppKit
import SwiftUI

@main
@MainActor
struct NestPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: PlayerModel

    init() {
        #if DEBUG && APP_STORE
        if ProcessInfo.processInfo.arguments.contains("--service-smoke") {
            BackendSmoke.start()
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
