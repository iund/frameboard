import Foundation
import Network

/// Private, loopback-only feed for OBS's browser source. No display capture is used.
final class LocalFrameServer {
    private let queue = DispatchQueue(label: "frameboard.obs.feed")
    private let lock = NSLock()
    private var jpeg: Data?
    private var listener: NWListener?
    private var startup: CheckedContinuation<URL, Error>?
    private var clients: [UUID: NWConnection] = [:]
    private let secret = UUID().uuidString

    func update(_ data: Data) { lock.lock(); jpeg = data; lock.unlock() }
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        return try await withCheckedThrowingContinuation { continuation in
            self.startup = continuation
            server.stateUpdateHandler = { state in
                guard let completion = self.startup else { return }
                switch state {
                case .ready:
                    self.startup = nil
                    guard let port = server.port else {
                        completion.resume(throwing: NSError(domain: "Frameboard", code: 1)); return
                    }
                    completion.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.secret)/index.html")!)
                case .failed(let error): self.startup = nil; completion.resume(throwing: error)
                case .cancelled: self.startup = nil; completion.resume(throwing: CancellationError())
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            server.start(queue: queue)
        }
    }
    func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            self.clients.values.forEach { $0.cancel() }; self.clients.removeAll()
        }
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 16 else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            connection?.cancel(); self?.clients.removeValue(forKey: id)
        }
        read(connection, id: id, buffer: Data())
    }
    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { return }
            let request = buffer + (data ?? Data())
            guard request.count <= 8192, error == nil else { self.finish(connection, id: id); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done { self.finish(connection, id: id) } else { self.read(connection, id: id, buffer: request) }
                return
            }
            let first = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
            guard first.count == 3, first[0] == "GET" else {
                self.respond(connection, id: id, code: "400 Bad Request", type: "text/plain", body: Data()); return
            }
            let path = String(first[1]).components(separatedBy: "?")[0]
            if path == "/\(self.secret)/index.html" {
                self.respond(connection, id: id, code: "200 OK", type: "text/html; charset=utf-8", body: Data(Self.page.utf8))
            } else if path == "/\(self.secret)/frame.jpg" {
                self.lock.lock(); let frame = self.jpeg; self.lock.unlock()
                self.respond(connection, id: id, code: frame == nil ? "503 Service Unavailable" : "200 OK", type: "image/jpeg", body: frame ?? Data())
            } else { self.respond(connection, id: id, code: "404 Not Found", type: "text/plain", body: Data()) }
        }
    }
    private func respond(_ connection: NWConnection, id: UUID, code: String, type: String, body: Data) {
        let header = "HTTP/1.1 \(code)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.finish(connection, id: id) })
    }
    private func finish(_ connection: NWConnection, id: UUID) { connection.cancel(); clients.removeValue(forKey: id) }
    static let page = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}
    canvas{display:block;width:100%;height:100%;object-fit:contain}
    </style></head><body><canvas width="1280" height="720"></canvas><script>
    const canvas=document.querySelector('canvas'),ctx=canvas.getContext('2d',{alpha:false});
    ctx.fillRect(0,0,1280,720);
    async function next(){const start=performance.now();try{
      const r=await fetch('frame.jpg',{cache:'no-store'});
      if(r.ok){const frame=await createImageBitmap(await r.blob());ctx.drawImage(frame,0,0,1280,720);frame.close();}
    }catch(e){}setTimeout(next,Math.max(0,50-(performance.now()-start)));}next();
    </script></body></html>
    """
}
