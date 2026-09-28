import AppKit
import Foundation
import AVFoundation
import Darwin

/// Owns only the OBS instance launched by Frameboard. Other OBS sessions are left alone.
@MainActor final class OBSController: ObservableObject {
    @Published var running = false
    @Published var busy = false
    @Published var status = "Start the virtual camera, then choose OBS Virtual Camera in your video app."
    @Published var needsOBS = false
    private let client = OBSClient()
    private var obs: NSRunningApplication?
    private var feedURL: URL?
    private var connected = false
    private var poll: Task<Void, Never>?
    private var originalControlConfig: Data?
    private var hadControlConfig = false
    private var modifiedControlConfig = false
    private var terminationObserver: NSObjectProtocol?
    private let scene = "Frameboard Managed"
    private let input = "Frameboard Video"
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("obs-studio")
    }
    private var controlConfig: URL { directory.appendingPathComponent("plugin_config/obs-websocket/config.json") }

    init() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // OBS receives its normal quit request; its own shutdown stops the virtual camera.
            MainActor.assumeIsolated { _ = self?.obs?.terminate() }
        }
    }
    func start(feed: LocalFrameServer, retryAfterApproval: Bool = true) async {
        guard !busy, !running else { return }
        busy = true; needsOBS = false; poll?.cancel(); poll = nil
        defer { busy = false }
        do {
            if feedURL == nil { feedURL = try await feed.start() }
            if obs?.isTerminated == true { await client.close(); connected = false; restoreControlConfig(); obs = nil }
            if !connected {
                guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.obsproject.obs-studio").isEmpty else {
                    throw OBSError(message: "OBS is already open independently. Quit that session once, then click Start virtual camera here.")
                }
                let installed = URL(fileURLWithPath: "/Applications/OBS.app")
                guard let application = FileManager.default.fileExists(atPath: installed.path) ? installed : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.obsproject.obs-studio") else {
                    needsOBS = true; throw OBSError(message: "Install OBS once, then return here. Frameboard handles its setup and controls.")
                }
                let port = try Self.unusedPort()
                let password = UUID().uuidString + UUID().uuidString
                try prepare(port: port, password: password)
                status = "Starting the camera service…"
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false; config.hides = true
                config.arguments = ["--minimize-to-tray", "--disable-updater", "--disable-missing-files-check", "--only-bundled-plugins", "--profile", scene, "--collection", scene, "--websocket_ipv4_only"]
                obs = try await NSWorkspace.shared.openApplication(at: application, configuration: config)
                var lastError: Error = OBSError(message: "OBS did not become ready.")
                for _ in 0..<20 {
                    do { try await client.connect(port: port, password: password); connected = true; break }
                    catch { lastError = error; try await Task.sleep(nanoseconds: 500_000_000) }
                    if obs?.isTerminated == true { break }
                }
                guard connected else { throw lastError }
                obs?.hide()
            }
            status = "Preparing the video feed…"
            try await configureSource()
            status = "Starting virtual camera. Approve OBS's camera extension if macOS asks."
            let existing = try await client.request("GetVirtualCamStatus")
            if existing["outputActive"] as? Bool != true { _ = try await client.request("StartVirtualCam") }
            // A successful request is not proof that the asynchronous extension activation finished.
            for _ in 0..<30 {
                let state = try await client.request("GetVirtualCamStatus")
                if state["outputActive"] as? Bool == true {
                    running = true; status = "Camera is on · Choose OBS Virtual Camera in your video app."
                    obs?.hide(); monitor(); return
                }
                // OBS can retain its first-install error dialog after macOS approval.
                // Restart only our idle instance once so its fresh device list sees the extension.
                let available = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .video, position: .unspecified).devices
                    .contains { $0.localizedName == "OBS Virtual Camera" }
                if retryAfterApproval && available {
                    status = "Finishing first-time camera setup…"
                    await client.close(); connected = false
                    _ = obs?.terminate()
                    for _ in 0..<30 {
                        if obs?.isTerminated != false { break }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard obs?.isTerminated != false else { throw OBSError(message: "The camera service is waiting for a dialog. Quit OBS once, then retry here.") }
                    restoreControlConfig(); obs = nil
                    busy = false
                    await start(feed: feed, retryAfterApproval: false)
                    return
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            throw OBSError(message: "Camera approval may be needed. Open macOS Camera Extensions, allow OBS, then click Start virtual camera again.")
        } catch {
            status = "Could not start: \(error.localizedDescription)"
            if !connected { obs?.terminate(); await client.close() }
        }
    }
    func stop() async {
        guard !busy else { return }
        busy = true; poll?.cancel(); poll = nil
        defer { busy = false }
        do {
            if connected {
                let state = try await client.request("GetVirtualCamStatus")
                if state["outputActive"] as? Bool == true { _ = try await client.request("StopVirtualCam") }
                let result = try await client.request("GetVirtualCamStatus")
                guard result["outputActive"] as? Bool == false else { throw OBSError(message: "OBS has not confirmed that the camera stopped.") }
            }
            running = false; status = "Camera is off. Webcam preview and tablet controls remain available."
        } catch { status = "Could not confirm camera stopped: \(error.localizedDescription)" }
    }
    func openApprovalSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
    }
    private func monitor() {
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard let self else { return }
                do {
                    let state = try await self.client.request("GetVirtualCamStatus")
                    guard !Task.isCancelled else { return }
                    if state["outputActive"] as? Bool != true {
                        self.running = false; self.status = "Virtual camera stopped. Click Start virtual camera to resume."; return
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.running = false; self.connected = false
                    self.status = "Connection to the camera service was lost. Quit OBS if it is still open, then retry."
                    return
                }
            }
        }
    }
    private func configureSource() async throws {
        _ = try await client.request("SetCurrentSceneCollection", ["sceneCollectionName": scene])
        _ = try await client.request("SetCurrentProfile", ["profileName": scene])
        let inputs = try await client.request("GetInputList")
        let exists = (inputs["inputs"] as? [[String: Any]] ?? []).contains { $0["inputName"] as? String == input }
        let settings: [String: Any] = ["url": feedURL!.absoluteString, "width": 1280, "height": 720, "fps": 20, "custom_fps": true,
                                      "shutdown": false, "restart_when_active": false, "reroute_audio": true]
        if exists { _ = try await client.request("SetInputSettings", ["inputName": input, "inputSettings": settings, "overlay": true]) }
        else { _ = try await client.request("CreateInput", ["sceneName": scene, "inputName": input, "inputKind": "browser_source", "inputSettings": settings, "sceneItemEnabled": true]) }
        _ = try await client.request("SetInputMute", ["inputName": input, "inputMuted": true])
        _ = try await client.request("SetCurrentProgramScene", ["sceneName": scene])
    }
    private func prepare(port: UInt16, password: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: controlConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        hadControlConfig = fm.fileExists(atPath: controlConfig.path)
        originalControlConfig = try? Data(contentsOf: controlConfig)
        if hadControlConfig, originalControlConfig == nil { throw OBSError(message: "Cannot read the existing OBS control settings.") }
        if let originalControlConfig {
            let backup = controlConfig.appendingPathExtension("frameboard-backup")
            if !fm.fileExists(atPath: backup.path) { try originalControlConfig.write(to: backup, options: .atomic); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path) }
        }
        var control: [String: Any] = [:]
        if let originalControlConfig {
            guard let parsed = try JSONSerialization.jsonObject(with: originalControlConfig) as? [String: Any] else { throw OBSError(message: "Existing OBS control settings are invalid.") }
            control = parsed
        }
        control["server_enabled"] = true; control["auth_required"] = true
        control["server_password"] = password; control["server_port"] = port
        control["first_load"] = false; control["alerts_enabled"] = false
        try JSONSerialization.data(withJSONObject: control).write(to: controlConfig, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: controlConfig.path)
        modifiedControlConfig = true
        // Seed only missing first-run files. Existing OBS scenes and profiles are preserved.
        try seed("global.ini", text: "[General]\nMacOSPermissionsDialogLastShown=1\nEnableAutoUpdates=false\n")
        try seed("user.ini", text: "[General]\nFirstRun=true\nConfirmOnExit=false\n[BasicWindow]\nSysTrayEnabled=true\nSysTrayWhenStarted=true\n")
        try seed("basic/profiles/FrameboardManaged/basic.ini", text: "[General]\nName=\(scene)\n[Video]\nBaseCX=1280\nBaseCY=720\nOutputCX=1280\nOutputCY=720\nFPSType=0\nFPSCommon=30\n[Audio]\nSampleRate=48000\nChannelSetup=Stereo\n")
        let collection = directory.appendingPathComponent("basic/scenes/FrameboardManaged.json")
        if !fm.fileExists(atPath: collection.path) {
            try fm.createDirectory(at: collection.deletingLastPathComponent(), withIntermediateDirectories: true)
            let json: [String: Any] = ["name": scene, "current_scene": scene, "current_program_scene": scene,
                "scene_order": [["name": scene]], "sources": [["name": scene, "id": "scene", "settings": ["items": []]]],
                "virtual-camera": ["type": 0]]
            try JSONSerialization.data(withJSONObject: json).write(to: collection, options: .atomic)
        }
    }
    private func seed(_ path: String, text: String) throws {
        let file = directory.appendingPathComponent(path), fm = FileManager.default
        guard !fm.fileExists(atPath: file.path) else { return }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
    }
    private func restoreControlConfig() {
        guard modifiedControlConfig else { return }
        if let originalControlConfig { try? originalControlConfig.write(to: controlConfig, options: .atomic) }
        else if !hadControlConfig { try? FileManager.default.removeItem(at: controlConfig) }
        modifiedControlConfig = false
    }
    private static func unusedPort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OBSError(message: "Cannot reserve a local control port.") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw OBSError(message: "Cannot bind a local control port.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard result == 0 else { throw OBSError(message: "Cannot read the control port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
