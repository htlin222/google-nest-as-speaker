import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct WebsiteLoginSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: WebsiteLoginRequest
    @State private var browserID = BrowserSession.installed.first?.id ?? "safari"
    @State private var remember = true

    private var browser: BrowserSession? { BrowserSession.installed.first { $0.id == browserID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Sign in to \(request.site)", systemImage: "person.crop.circle.badge.checkmark")
                .font(.title2.bold())
            Text(request.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Browser", selection: $browserID) {
                ForEach(BrowserSession.installed) { Text($0.name).tag($0.id) }
            }
            Text("1. Open the video in this browser and sign in. You can use the website's normal Google login, QR code, or two-factor authentication.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Open \(request.site) in browser", systemImage: "safari") {
                if let browser { model.openLogin(in: browser, for: request) }
            }
            .disabled(browser == nil)
            Text("2. Return here when the video plays in your browser, then use that browser session.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Use this browser for this site until I quit Nest Player", isOn: $remember)
            Text("Browser cookies are read only after you press Use Session. macOS may ask for Keychain or cookie-file access. Nest Player keeps them in memory and does not store your password or cookies.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Forget browser access") { model.forgetWebsiteSessions() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Use Session & Play") {
                    if let browser { model.retryLogin(request, browser: browser, remember: remember) }
                }
                .buttonStyle(.borderedProminent).disabled(browser == nil)
            }
        }
        .padding(28).frame(width: 560)
    }
}

struct SMBConnectionSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chooseFolder: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            Label("Connect a network folder", systemImage: "externaldrive.connected.to.line.below")
                .font(.title2.bold())
            Text("1. Enter the SMB server or share. Finder will handle login and can remember your credentials in the macOS Keychain.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("smb://server/share", text: $model.smbAddress).textFieldStyle(.roundedBorder)
            Button("Connect in Finder", systemImage: "network") { model.connectSMB() }
                .disabled(SMBAddress.parse(model.smbAddress) == nil)
            Text("2. Once connected, choose a folder from the mounted share. Its audio and video files will be scanned in the background.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Keep the share mounted while playing. If the NAS goes offline, its playlist entries stay available for reconnection.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Choose Mounted Folder…") { chooseFolder(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28).frame(width: 530)
    }
}

struct PhoneRemoteSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var manualURL: String {
        guard let url = model.remoteURL, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        components.query = nil
        return components.string ?? ""
    }

    var body: some View {
        VStack(spacing: 18) {
            Label("iPhone Remote", systemImage: "iphone.and.arrow.forward").font(.title2.bold())
            Text("Scan with your iPhone camera to open the controller.")
                .foregroundStyle(.secondary)
            if let url = model.remoteURL, let image = qrCode(url.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: 230, height: 230).padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                Text(manualURL).font(.body.monospaced()).textSelection(.enabled)
                Text("Manual pairing code: \(model.pairingCode)").font(.headline.monospacedDigit())
                Text("Keep this Mac awake and Nest Player open. Use the same LAN or Wi-Fi. A paired phone stays paired across launches — on iPhone, Share → Add to Home Screen, open it and enter the code once.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Copy Remote Link", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
                    Button("Reset Pairing", systemImage: "arrow.triangle.2.circlepath", role: .destructive) {
                        model.resetRemotePairing()
                    }
                    .help("Disconnect every paired phone, e.g. after losing one")
                }
            } else {
                ProgressView("Starting the phone controller…").frame(height: 220)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(28).frame(width: 470)
        .onAppear { model.loadRemoteInfo() }
    }

    private func qrCode(_ value: String) -> NSImage? {
        // https://developer.apple.com/documentation/coreimage/cifilter/3256055-qrcodegenerator
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
