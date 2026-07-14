import Foundation
import Network

/// A tiny loopback-only HTTP server that speaks MCP's Streamable-HTTP shape:
/// the agent POSTs a JSON-RPC message and gets the JSON-RPC reply as the
/// response body. Bound to 127.0.0.1 so it is never reachable off the machine.
/// Off until the user enables agent access.
public final class AgentServer {
    public let handler: MCPHandler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.yarden.designer.agent")
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public private(set) var port: UInt16 = 0
    public var isRunning: Bool { listener != nil }
    /// The URL to hand to an MCP client (e.g. Claude Desktop).
    public var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }

    public init(bridge: AgentBoardBridge? = nil) {
        handler = MCPHandler(bridge: bridge)
    }

    /// Starts the listener. Uses `preferredPort` when free, otherwise an
    /// The port MCP clients are told to configure; stays stable across
    /// launches unless something else has claimed it.
    public static let defaultPort: UInt16 = 51737

    /// OS-assigned ephemeral port (read `port` after `onReady`).
    public func start(preferredPort: UInt16 = AgentServer.defaultPort, onReady: ((UInt16) -> Void)? = nil) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback // 127.0.0.1 only — not on the LAN
        let nwPort = NWEndpoint.Port(rawValue: preferredPort) ?? .any
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = listener.port {
                    self.port = p.rawValue
                    onReady?(p.rawValue)
                }
            case .failed:
                // Preferred port taken (or bind failed): fall back to an
                // OS-assigned ephemeral port instead of dying silently.
                if preferredPort != 0 {
                    try? self.start(preferredPort: 0, onReady: onReady)
                }
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        port = 0
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections.removeValue(forKey: key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    /// Accumulates bytes until a full HTTP request (headers + Content-Length
    /// body) is in hand, then services it.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest(buffer) {
                self.service(request, on: connection)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, buffer: buffer)
        }
    }

    private func service(_ request: HTTPRequest, on connection: NWConnection) {
        // Reject browser-originated requests: a web page can fire cross-origin
        // POSTs at localhost even if it can't read the reply. MCP clients
        // don't send an Origin header; browsers always do.
        if let origin = request.headers["origin"],
           !origin.hasPrefix("http://127.0.0.1"), !origin.hasPrefix("http://localhost") {
            respond(on: connection, status: "403 Forbidden", contentType: "text/plain",
                    body: Data("Browser origins are not allowed.\n".utf8))
            return
        }
        // Streamable HTTP: we don't offer a GET/SSE stream, so say so per spec.
        guard request.method == "POST" else {
            respond(on: connection, status: "405 Method Not Allowed", contentType: "text/plain",
                    extraHeaders: ["Allow": "POST"],
                    body: Data("Designer agent endpoint. POST JSON-RPC (MCP) here.\n".utf8))
            return
        }
        if let responseBody = handler.handle(request.body) {
            respond(on: connection, status: "200 OK", contentType: "application/json", body: responseBody)
        } else {
            // A notification: acknowledge with no content.
            respond(on: connection, status: "202 Accepted", contentType: "application/json", body: Data())
        }
    }

    private func respond(
        on connection: NWConnection, status: String, contentType: String,
        extraHeaders: [String: String] = [:], body: Data
    ) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        for (key, value) in extraHeaders {
            header += "\(key): \(value)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Just enough HTTP/1.1 request parsing for the loopback MCP endpoint.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String] // keys lowercased
    let body: Data

    init?(_ buffer: Data) {
        // Find the header/body boundary.
        guard let range = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[buffer.startIndex..<range.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1])

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            parsedHeaders[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                pair[1].trimmingCharacters(in: .whitespaces)
        }
        headers = parsedHeaders
        let contentLength = Int(parsedHeaders["content-length"] ?? "") ?? 0
        let bodyStart = range.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil } // wait for more bytes
        body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)])
    }
}
