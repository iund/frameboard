import Foundation

@main struct LocalFrameServerTests {
    static func main() async throws {
        let feed = LocalFrameServer()
        let url = try await feed.start()
        defer { feed.stop() }
        precondition(url.host == "127.0.0.1")
        let (page, pageResponse) = try await URLSession.shared.data(from: url)
        precondition((pageResponse as! HTTPURLResponse).statusCode == 200)
        precondition(String(decoding: page, as: UTF8.self).contains("createImageBitmap"))
        let frameURL = url.deletingLastPathComponent().appendingPathComponent("frame.jpg")
        let (_, emptyResponse) = try await URLSession.shared.data(from: frameURL)
        precondition((emptyResponse as! HTTPURLResponse).statusCode == 503)
        let fixture = Data([0xff, 0xd8, 0x01, 0x02, 0xff, 0xd9])
        feed.update(fixture)
        let (image, imageResponse) = try await URLSession.shared.data(from: frameURL)
        precondition(image == fixture)
        precondition((imageResponse as! HTTPURLResponse).value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let (_, denied) = try await URLSession.shared.data(from: url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("frame.jpg"))
        precondition((denied as! HTTPURLResponse).statusCode == 404)
        feed.update(Data([3, 4, 5]))
        let (latest, _) = try await URLSession.shared.data(from: frameURL)
        precondition(latest == Data([3, 4, 5]))
        print("PASS: loopback binding, page, missing frame, exact bytes, cache policy, secret path, latest-frame replacement")
    }
}
