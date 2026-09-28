import CoreMediaIO
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import CoreGraphics
import IOKit.audio

final class FrameboardProvider: NSObject, CMIOExtensionProviderSource {
    lazy var provider = CMIOExtensionProvider(source: self, clientQueue: queue)
    private var deviceSource: CameraDeviceSource!
    private var streamSource: CameraStreamSource!
    private var streamClients = 0
    private var device: CMIOExtensionDevice!
    private var stream: CMIOExtensionStream!
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "frameboard.extension.frames")
    private var lastGoodImage: CGImage?
    private let videoDescription: CMVideoFormatDescription
    private let frameDuration = CMTime(value: 1, timescale: 30)
    var activeFormatIndex: Int = 0

    override init() {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: 1280, height: 720, extensions: nil, formatDescriptionOut: &format)
        videoDescription = format!
        super.init()
        deviceSource = CameraDeviceSource()
        streamSource = CameraStreamSource(owner: self)
        device = CMIOExtensionDevice(localizedName: "Frameboard Camera", deviceID: UUID(uuidString: "2db12189-9ac3-4ce9-a2da-a559062d8f4a")!, legacyDeviceID: nil, source: deviceSource)
        stream = CMIOExtensionStream(localizedName: "Frameboard Video", streamID: UUID(uuidString: "01f7da90-1c57-4f8b-aa62-3a3b05675c71")!, direction: .source, clockType: .hostTime, source: streamSource)
        do { try device.addStream(stream); try provider.addDevice(device) }
        catch { fatalError("Cannot register Frameboard camera: \(error)") }
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Frameboard" }
        return result
    }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:]); result.activeFormatIndex = 0; result.frameDuration = frameDuration; return result
    }
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    var formats: [CMIOExtensionStreamFormat] {
        [CMIOExtensionStreamFormat(formatDescription: videoDescription, maxFrameDuration: frameDuration, minFrameDuration: frameDuration, validFrameDurations: nil)]
    }
    func startStream() throws {
        streamClients += 1
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0/30.0)
        t.setEventHandler { [weak self] in self?.emitTestFrame() }
        t.resume(); timer = t
    }
    func stopStream() throws {
        streamClients = max(0, streamClients - 1)
        if streamClients == 0 { timer?.cancel(); timer = nil }
    }
    private func emitTestFrame() {
        var buffer: CVPixelBuffer?
        let attributes: [CFString:Any] = [kCVPixelBufferCGImageCompatibilityKey:true, kCVPixelBufferCGBitmapContextCompatibilityKey:true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let base=CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
            if let folder=FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Bundle.main.object(forInfoDictionaryKey: "FrameboardAppGroup") as? String ?? ""),
               let bytes=try? Data(contentsOf:folder.appendingPathComponent("latest.jpg")),
               let imageSource=CGImageSourceCreateWithData(bytes as CFData,nil),
               let image=CGImageSourceCreateImageAtIndex(imageSource,0,nil) {
                lastGoodImage = image
            }
            if let image = lastGoodImage, let context=CGContext(data:base,width:1280,height:720,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.draw(image,in:CGRect(x:0,y:0,width:1280,height:720))
            }
        }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { return }
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: hostTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(CMTimeConvertScale(hostTime, timescale: 1_000_000_000, method: .default).value))
    }
}

private final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "Frameboard Camera" }
        return result
    }
    func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {}
}

private final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    unowned let owner: FrameboardProvider
    init(owner: FrameboardProvider) { self.owner = owner; super.init() }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }
    var formats: [CMIOExtensionStreamFormat] { owner.formats }
    var activeFormatIndex: Int = 0
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        try owner.streamProperties(forProperties: properties)
    }
    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
        if let index = properties.activeFormatIndex, index != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCMIOHardwareIllegalOperationError))
        }
        if let duration = properties.frameDuration, CMTimeCompare(duration, CMTime(value: 1, timescale: 30)) != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCMIOHardwareIllegalOperationError))
        }
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { try owner.startStream() }
    func stopStream() throws { try owner.stopStream() }
}
