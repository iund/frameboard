import AVFoundation
import AppKit
import CoreImage
import Network
import Darwin

/// Host capture and tablet control, independent of pairing availability.
final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let localFeed = LocalFrameServer()
    @Published var preview: NSImage?
    @Published var status = "Starting webcam…"
    @Published var connected = false
    @Published var lanPort = "Starting…"
    @Published private var pairingCode: PairingCode?
    let previewOnly = UserDefaults.standard.bool(forKey: "FrameboardPreviewOnly")
    var pairingToken: String { token }
    var lanAddresses: String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return "Check Wi-Fi settings" }
        defer { freeifaddrs(interfaces) }
        var values = [String]()
        var cursor = interfaces
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (current.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                values.append(String(cString: host))
            }
        }
        return values.isEmpty ? "Check Wi-Fi settings" : values.joined(separator: ", ")
    }
    private let session = AVCaptureSession()
    private let imageContext = CIContext()
    private var started = false
    private var authenticated = false
    private var previewInFlight = false
    private let captureQueue = DispatchQueue(label: "frameboard.capture")
    private let token = UUID().uuidString
    private let pairingIdentity = PairingIdentity.loadOrCreate()
    private var listener: NWListener?
    private var peer: NWConnection?
    private var receiveBuffer = Data()
    private var serverNonce: Data?
    private var secureChannel: SecureChannel?
    private var lastPreview = Date.distantPast
    private var rectangle = CGRect(x: 0.54, y: 0.08, width: 0.4, height: 0.4)
    private var strokes = [[CGPoint]]()
    private var lastSharedFrame = Date.distantPast

    func start() {
        guard !started else { return }
        started = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted { self.startCapture() }
            else { DispatchQueue.main.async { self.status = "Camera permission denied" } }
        }
        startLAN()
    }
    private func startCapture() {
        captureQueue.async {
            // Exclude our own virtual camera, even if it becomes the app's preferred device.
            let physical = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified).devices
                .first { !$0.localizedName.contains("Frameboard") && !$0.localizedName.localizedCaseInsensitiveContains("OBS") }
            guard let physical, let input = try? AVCaptureDeviceInput(device: physical) else {
                DispatchQueue.main.async { self.status = "No physical webcam found" }; return
            }
            self.session.beginConfiguration()
            if self.session.canAddInput(input) { self.session.addInput(input) }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.captureQueue)
            if self.session.canAddOutput(output) { self.session.addOutput(output) }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { self.status = "Webcam live · Connecting to tablet…" }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cg = imageContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        guard let jpeg = compose(cg) else { return }
        localFeed.update(jpeg)
        if let composed = NSImage(data: jpeg) { DispatchQueue.main.async { self.preview = composed } }
        if Date().timeIntervalSince(lastSharedFrame) > 1.0/20.0 {
            lastSharedFrame = Date()
            if !previewOnly, let folder=FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Bundle.main.object(forInfoDictionaryKey: "FrameboardAppGroup") as? String ?? "") {
                try? jpeg.write(to: folder.appendingPathComponent("latest.jpg"), options: .atomic)
            }
        }
        if Date().timeIntervalSince(lastPreview) > 0.2, authenticated, !previewInFlight, let connection = peer {
            lastPreview = Date()
            previewInFlight = true
            send(["type":"preview", "jpeg":jpeg.base64EncodedString()]) { [weak self] in
                self?.captureQueue.async {
                    guard let self, self.peer === connection else { return }
                    self.previewInFlight = false
                }
            }
        }
    }
    private func compose(_ camera: CGImage) -> Data? {
        let width=1280, height=720
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let context=NSGraphicsContext(bitmapImageRep:bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=context
        NSColor.black.setFill();NSBezierPath(rect: NSRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height))).fill()
        NSColor.white.setStroke()
        for line in strokes where !line.isEmpty {
            let path=NSBezierPath(); path.lineWidth=4;path.lineCapStyle = .round
            path.move(to:NSPoint(x:line[0].x*CGFloat(width),y:(1-line[0].y)*CGFloat(height)))
            for point in line.dropFirst() { path.line(to:NSPoint(x:point.x*CGFloat(width),y:(1-point.y)*CGFloat(height))) }
            if line.count == 1 { path.line(to:NSPoint(x:line[0].x*CGFloat(width)+1,y:(1-line[0].y)*CGFloat(height))) }
            path.stroke()
        }
        let target=NSRect(x:rectangle.minX*CGFloat(width),y:(1-rectangle.maxY)*CGFloat(height),width:rectangle.width*CGFloat(width),height:rectangle.height*CGFloat(height))
        let source = NSImage(cgImage:camera,size:NSSize(width:CGFloat(camera.width),height:CGFloat(camera.height)))
        // Preserve the entire source image; letterbox when aspect ratios differ.
        NSColor.black.setFill(); NSBezierPath(rect: target).fill()
        let scale = min(target.width / CGFloat(camera.width), target.height / CGFloat(camera.height))
        let fit = NSRect(x: target.midX - CGFloat(camera.width)*scale/2,
                         y: target.midY - CGFloat(camera.height)*scale/2,
                         width: CGFloat(camera.width)*scale, height: CGFloat(camera.height)*scale)
        source.draw(in:fit,from:NSRect(x:0,y:0,width:camera.width,height:camera.height),operation:.copy,fraction:1)
        context.flushGraphics();NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.7])
    }
    var pairingQRCode: NSImage? {
        pairingCode?.image
    }
    var pairingFingerprint:String? {
        pairingCode?.fingerprint
    }
    private func startLAN() {
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.service = NWListener.Service(name: "Frameboard", type: "_frameboard._tcp")
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                DispatchQueue.main.async {
                    if case .ready = state, let self, let port=listener?.port?.rawValue {
                        self.lanPort=String(port)
                        if let host=self.lanAddresses.components(separatedBy:", ").first,!host.isEmpty {
                            self.pairingCode=self.pairingIdentity?.code(host:host,port:port,secret:self.token)
                        }
                    }
                    if case .failed(let error) = state { self?.lanPort = "Failed: \(error.localizedDescription)" }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: captureQueue)
            self.listener = listener
        } catch { DispatchQueue.main.async { self.status = "LAN service failed: \(error.localizedDescription)" } }
    }
    private func accept(_ connection: NWConnection) {
        guard !authenticated else { connection.cancel(); return }
        peer?.cancel(); peer = connection; receiveBuffer.removeAll()
        authenticated = false; previewInFlight = false; secureChannel = nil
        let nonce = SecureChannel.randomNonce(); serverNonce = nonce
        DispatchQueue.main.async { self.connected = false }
        connection.start(queue: captureQueue)
        sendPlain(["type":"challenge", "version":2, "serverNonce":nonce.base64EncodedString()], on:connection)
        readLine(connection)
        captureQueue.asyncAfter(deadline:.now()+10) { [weak self, weak connection] in
            guard let self, let connection, self.peer === connection, !self.authenticated else { return }
            self.disconnect(connection)
        }
    }
    private func readLine(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, self.peer === connection else { return }
            if let data { self.receiveBuffer.append(data) }
            guard self.receiveBuffer.count <= 3_000_000 else { self.disconnect(connection); return }
            while let end = self.receiveBuffer.firstIndex(of: 10) {
                let line = self.receiveBuffer.prefix(upTo: end)
                self.receiveBuffer.removeSubrange(...end)
                guard let envelope = (try? JSONSerialization.jsonObject(with: line)) as? [String:Any] else { self.disconnect(connection); return }
                if !self.authenticated { self.authenticate(envelope, connection:connection) }
                else {
                    guard let message = try? self.secureChannel?.open(envelope) else { self.disconnect(connection); return }
                    self.apply(message)
                }
            }
            if done || error != nil { self.disconnect(connection) }
            else { self.readLine(connection) }
        }
    }
    private func authenticate(_ message:[String:Any], connection:NWConnection) {
        guard message["type"] as? String == "authenticate", (message["version"] as? NSNumber)?.intValue == 2,
              let serverNonce, let clientText=message["clientNonce"] as? String, let clientNonce=Data(base64Encoded:clientText), clientNonce.count == SecureChannel.nonceBytes,
              let proofText=message["proof"] as? String, let proof=Data(base64Encoded:proofText),
              SecureChannel.validClientProof(proof,secret:token,serverNonce:serverNonce,clientNonce:clientNonce) else { disconnect(connection); return }
        let serverProof=SecureChannel.serverProof(secret:token,serverNonce:serverNonce,clientNonce:clientNonce)
        sendPlain(["type":"authenticated","version":2,"proof":serverProof.base64EncodedString()],on:connection) { [weak self, weak connection] in
            guard let self, let connection, self.peer === connection else { return }
            self.secureChannel=SecureChannel.server(secret:self.token,serverNonce:serverNonce,clientNonce:clientNonce)
            self.authenticated=true
            self.send(["type":"status","state":"connected"])
            self.send(["type":"layout","x":self.rectangle.minX,"y":self.rectangle.minY,"w":self.rectangle.width,"h":self.rectangle.height])
            DispatchQueue.main.async { self.connected=true;self.status="Tablet connected securely" }
        }
    }
    private func disconnect(_ connection:NWConnection) {
        connection.cancel()
        guard peer === connection else { return }
        peer=nil;authenticated=false;secureChannel=nil;serverNonce=nil;previewInFlight=false;receiveBuffer.removeAll()
        DispatchQueue.main.async { self.connected=false;self.status="Webcam live · Tablet disconnected" }
    }
    private func apply(_ m: [String:Any]) {
        switch m["type"] as? String {
        case "layout":
            let x=m["x"] as? Double ?? 0, y=m["y"] as? Double ?? 0, w=m["w"] as? Double ?? 1, h=m["h"] as? Double ?? 1
            guard w >= 0.1, h >= 0.1, x >= 0, y >= 0, x+w <= 1.001, y+h <= 1.001 else { return }
            rectangle=CGRect(x:x,y:y,width:w,height:h)
        case "stroke":
            if let points=m["points"] as? [[Double]], !points.isEmpty, points.count <= 4096,
               strokes.count < 1024, strokes.reduce(0, { $0 + $1.count }) + points.count <= 65536,
               points.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) {
                strokes.append(points.map { CGPoint(x:$0[0],y:$0[1]) })
            }
        case "erase":
            let x=m["x"] as? Double ?? -1,y=m["y"] as? Double ?? -1,r=m["radius"] as? Double ?? 0
            guard x.isFinite, y.isFinite, r.isFinite, (0...1).contains(x), (0...1).contains(y), r > 0, r <= 0.1 else { return }
            strokes.removeAll { $0.contains { hypot($0.x-CGFloat(x),$0.y-CGFloat(y)) < CGFloat(r) } }
        case "clear": strokes.removeAll()
        default: break
        }
    }
    private func send(_ value: [String:Any], completion: @escaping () -> Void = {}) {
        guard authenticated, let secureChannel, let envelope=try? secureChannel.seal(value),
              let data=try? JSONSerialization.data(withJSONObject:envelope), let peer else { return }
        peer.send(content:data+Data([10]), completion:.contentProcessed { _ in completion() })
    }
    private func sendPlain(_ value:[String:Any],on connection:NWConnection,completion:@escaping()->Void={}) {
        guard let data=try? JSONSerialization.data(withJSONObject:value) else { return }
        connection.send(content:data+Data([10]),completion:.contentProcessed { error in if error == nil { completion() } })
    }
}
