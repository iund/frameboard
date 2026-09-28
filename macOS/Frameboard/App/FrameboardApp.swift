import SwiftUI
import SystemExtensions

@main struct FrameboardApp: App {
    @StateObject private var model = CameraModel()
    @StateObject private var installer = ExtensionInstaller()
    @StateObject private var obs = OBSController()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model).environmentObject(installer).environmentObject(obs)
                .frame(minWidth: 780, minHeight: 720)
                .onAppear { model.start() }
                .task {
                    if UserDefaults.standard.bool(forKey: "FrameboardStartCamera") { await obs.start(feed: model.localFeed) }
                }
        }
    }
}

final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Install the virtual camera after configuring development signing."
    @Published var pending = false
    func activate() {
        guard !pending else { return }
        let identifier = (Bundle.main.bundleIdentifier ?? "com.example.frameboard") + ".cameraextension"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pending = true; status = "Requesting camera extension activation…"
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve Frameboard in System Settings → General → Login Items & Extensions → Camera Extensions."
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        pending = false
        status = result == .completed ? "Virtual camera installed. Choose Frameboard Camera in your video app." : "Restart your Mac to finish installing the virtual camera."
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        pending = false; status = "Installation failed: \(error.localizedDescription)"
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
}

struct ContentView: View {
    @EnvironmentObject var model: CameraModel
    @EnvironmentObject var installer: ExtensionInstaller
    @EnvironmentObject var obs: OBSController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Frameboard Camera").font(.title2.bold())
                    Spacer()
                    Text(model.connected ? "● Tablet connected" : "Tablet not connected")
                        .foregroundStyle(model.connected ? .green : .secondary)
                }
                if let image = model.preview {
                    Image(nsImage: image).resizable().aspectRatio(16.0/9.0, contentMode: .fit).background(.black)
                } else {
                    Rectangle().fill(.black).aspectRatio(16.0/9.0, contentMode: .fit)
                        .overlay(Text("Allow camera access to preview").foregroundStyle(.white))
                }
                Text(model.status).foregroundStyle(.secondary)
                if !model.connected { GroupBox("Connect the Android tablet") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use the same Wi-Fi, tap Connect on Android, and scan this signed pairing code.")
                        if let image=model.pairingQRCode {
                            Image(nsImage:image).interpolation(.none).resizable().frame(width:220,height:220)
                            Text("Mac identity: \(model.pairingFingerprint ?? "Unavailable")").font(.system(.body,design:.monospaced).bold())
                            Text("Confirm this identity on the tablet the first time. The tablet pins it for later connections.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else { ProgressView("Preparing pairing code…") }
                        DisclosureGroup("Manual connection details") {
                            Text("Mac addresses: \(model.lanAddresses)")
                            Text("Port: \(model.lanPort)")
                            Text("Session secret: \(model.pairingToken)").font(.system(.body,design:.monospaced))
                        }
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                } }
                GroupBox("Virtual camera") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(obs.running ? "Stop virtual camera" : "Start virtual camera") {
                                Task { if obs.running { await obs.stop() } else { await obs.start(feed: model.localFeed) } }
                            }.disabled(obs.busy)
                            if obs.busy { ProgressView().controlSize(.small) }
                            if obs.needsOBS { Link("Install OBS", destination: URL(string: "https://obsproject.com/download")!) }
                        }
                        Text(obs.status)
                        Text("OBS runs in the background. Frameboard sets up the video feed automatically; no OBS scenes or capture windows to configure.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open camera-extension settings") { obs.openApprovalSettings() }
                        DisclosureGroup("Advanced: standalone Frameboard camera") {
                            Text("Requires Apple development signing. The OBS option above works without a development team.")
                            Button("Install standalone camera") { installer.activate() }.disabled(installer.pending || model.previewOnly)
                            Text(installer.status).font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(24)
        }
    }
}
