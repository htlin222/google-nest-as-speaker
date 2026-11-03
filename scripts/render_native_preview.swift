import AppKit
import SwiftUI

/// Render the production SwiftUI view with isolated, fictional state.
/// This captures our own NSView, not the desktop or any user window.
@main
@MainActor
enum RenderNativePreview {
    static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let destination = CommandLine.arguments.dropFirst().first ?? "assets/screenshots/native-player.png"
        let model = PlayerModel(preview: true)
        let controller = NSHostingController(rootView: ContentView().environment(model).preferredColorScheme(.dark))
        let view = controller.view
        let size = NSSize(width: 1100, height: 730)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(size)
        window.title = "Nest Player — Documentation Preview"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        model.currentTime = 205
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        model.currentTime = 204
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        let target = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--screen-capture") {
            // Opt-in real window capture requires the user's macOS permission.
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), target.path]
            try capture.run()
            capture.waitUntilExit()
            guard capture.terminationStatus == 0 else { throw CocoaError(.fileReadNoPermission) }
        } else {
            // Snapshot only our own generated NSView hierarchy from memory.
            window.display()
            view.display()
            // Capture the SwiftUI playback panel only. Layer-backed sidebar lists
            // are not included in an AppKit in-memory snapshot and must not be faked.
            let renderedWidth = min(view.bounds.width, window.screen?.frame.width ?? view.bounds.width)
            let panel = NSRect(x: 355, y: 0, width: renderedWidth - 355, height: view.bounds.height)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: panel) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: panel, to: bitmap)
            // AppKit can allocate unused transparent/black columns beyond the
            // rendered panel. Frame the capture around the actual view pixels.
            var pixelWidth = bitmap.pixelsWide
            while pixelWidth > 1 {
                let empty = stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 64)).allSatisfy { row in
                    guard let color = bitmap.colorAt(x: pixelWidth - 1, y: row)?.usingColorSpace(.deviceRGB) else { return true }
                    return color.alphaComponent < 0.01 || max(color.redComponent, color.greenComponent, color.blueComponent) < 0.01
                }
                if !empty { break }
                pixelWidth -= 1
            }
            guard let cgImage = bitmap.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: pixelWidth, height: bitmap.pixelsHigh)),
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: target)
        }
        print(target.path)
        window.close()
    }
}
