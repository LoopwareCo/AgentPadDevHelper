#if DEBUG
import Foundation
import Network

/// Small loopback-only HTTP endpoint, DEBUG-only: answers a bare-bones JSON-RPC surface
/// (`initialize`, `tools/list`, `tools/call`) on `127.0.0.1:<port>`, routed through the same
/// `DevToolHandler` the dial-out transport (`DevKitClient`) uses for a relayed call. This is what
/// lets THIS process's own `ui_*`/widget tools be driven directly — by another AgentPad, or `curl` —
/// without a second instance to relay through. Restores the harness the viewer used before dev apps
/// switched to dialing OUT to AgentPad (see AGENTS.md "UI-driver verification").
///
/// No Bonjour, no TXT records, no icon route — just the one endpoint, bound to loopback only.
final class LoopbackDriver {
    static let shared = LoopbackDriver()
    private let q = DispatchQueue(label: "agentpad.devkit.loopbackdriver")
    private let handler = DevToolHandler()
    private var listener: NWListener?
    private var started = false
    private var conns: [ObjectIdentifier: Conn] = [:]   // retain each connection until it closes

    func start(port: UInt16) {
        q.async { [weak self] in self?.startOnQueue(port: port) }
    }

    private func startOnQueue(port: UInt16) {
        guard !started, let p = NWEndpoint.Port(rawValue: port) else { return }
        started = true
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // The port rides IN requiredLocalEndpoint — passing it to `NWListener(using:on:)` as well
        // makes the initializer throw (conflicting port specs), which `try?` silently swallowed.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: p)   // loopback-only
        guard let l = try? NWListener(using: params) else {
            NSLog("AgentPadDevHelper: loopback driver failed to bind 127.0.0.1:\(port)"); return
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { state in
            if case .failed(let e) = state { NSLog("AgentPadDevHelper: loopback driver listener failed: \(e)") }
        }
        l.start(queue: q)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: q)
        let c = Conn(conn: conn, handler: handler, owner: self)
        conns[ObjectIdentifier(conn)] = c   // retain until it closes
        c.process()
    }

    fileprivate func drop(_ conn: NWConnection) {
        q.async { [weak self] in self?.conns[ObjectIdentifier(conn)] = nil }
    }

    // MARK: - one HTTP/1.1 connection: parse a request, dispatch, reply, repeat

    private final class Conn {
        let conn: NWConnection
        let handler: DevToolHandler
        unowned let owner: LoopbackDriver
        var buffer = Data()
        init(conn: NWConnection, handler: DevToolHandler, owner: LoopbackDriver) {
            self.conn = conn; self.handler = handler; self.owner = owner
        }

        func process() {
            if let body = parse() {
                dispatch(body) { [weak self] in self?.process() }
            } else {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
                    guard let self else { return }
                    if let data, !data.isEmpty { self.buffer.append(data) }
                    if done || err != nil { self.conn.cancel(); self.owner.drop(self.conn); return }
                    self.process()
                }
            }
        }

        /// Pull one complete HTTP request's BODY out of `buffer` (consuming it), or nil if more bytes
        /// are needed. The request line/method/path aren't inspected — this endpoint has exactly one
        /// job, so any POST is routed the same way.
        private func parse() -> Data? {
            guard let r = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(data: buffer.subdata(in: buffer.startIndex..<r.lowerBound), encoding: .utf8) ?? ""
            var contentLength = 0
            for line in head.components(separatedBy: "\r\n").dropFirst() where line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            let bodyStart = r.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }
            let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            return body
        }

        private func dispatch(_ body: Data, then done: @escaping () -> Void) {
            guard let msg = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                writeJSON(["jsonrpc": "2.0", "error": ["code": -32700, "message": "parse error"]]); done(); return
            }
            let method = msg["method"] as? String ?? ""
            let id = msg["id"]
            switch method {
            case "initialize":
                writeJSON(result(id, ["protocolVersion": "2024-11-05", "capabilities": ["tools": [String: Any]()],
                                      "serverInfo": ["name": "AgentPad", "version": "1"]]))
                done()
            case "tools/list":
                writeJSON(result(id, ["tools": Self.toolNames.map { ["name": $0, "inputSchema": ["type": "object"]] as [String: Any] }]))
                done()
            case "tools/call":
                let params = msg["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                handler.call(name, arguments: args) { [weak self] text, isError in
                    guard let self else { return }
                    self.writeJSON(self.result(id, ["content": [["type": "text", "text": text]], "isError": isError]))
                    done()
                }
            default:
                writeJSON(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32601, "message": "method not found: \(method)"]])
                done()
            }
        }

        /// Mirrors `DevToolHandler.call`'s switch — kept minimal (no real JSON Schema) since this
        /// endpoint is only ever driven by another AgentPad or a hand-written `curl`, not a strict
        /// MCP client.
        private static let toolNames = ["ui_snapshot", "ui_find", "ui_act", "ui_setvalue", "ui_inspect",
                                        "ui_focus", "ui_key", "ui_shot", "widgets_list", "widgets_values", "widget_set"]

        private func result(_ id: Any?, _ r: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": r] }

        private func writeJSON(_ obj: [String: Any]) {
            let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n".utf8)
            resp.append(body)
            conn.send(content: resp, completion: .contentProcessed { _ in })
        }
    }
}
#endif
