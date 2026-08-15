import Foundation
import Network
#if os(macOS)
import Darwin
#endif

/// Dial-out client for the AgentPadDevHelper transport: this app connects OUT to AgentPad's ingress
/// (a Unix socket + loopback TCP listener — see `AgentPadServerCore.DevKitIngress`) instead of
/// hosting a listener itself. Sandboxed apps (App Sandbox, Simulator) can't host, but loopback
/// dial-out is safe everywhere.
///
/// Connects to EVERY reachable ingress endpoint at once (so a dev AND a release AgentPad on the same
/// Mac both see this app live), deduping by the `welcome` frame's `server`+`flavor` so the SAME
/// logical server reached over two transports (e.g. Unix socket AND loopback TCP) only gets one live
/// registration. Each endpoint reconnects forever with 2s→30s backoff — AgentPad may not be running
/// yet, or may restart later.
final class DevKitClient {
    static let shared = DevKitClient()
    private init() {}

    private let dev = AgentPadDev.shared
    private let handler = DevToolHandler()

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]        // endpoint.label → session
    private var claimedBy: [String: String] = [:]        // "server|flavor" → the endpoint.label holding it
    private var started = false

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        AppIdentity.prepareIcon()
        dev.onWidgetsChanged = { [weak self] in self?.broadcastWidgets() }
        dev.onValueChanged = { [weak self] widgetId, json in self?.broadcastValue(widgetId, json) }

        for endpoint in Self.candidateEndpoints() {
            let session = Session(endpoint: endpoint, client: self)
            lock.lock(); sessions[endpoint.label] = session; lock.unlock()
            session.start()
        }
    }

    func stop() {
        lock.lock()
        started = false
        let all = Array(sessions.values)
        sessions.removeAll()
        claimedBy.removeAll()
        lock.unlock()
        all.forEach { $0.stop() }
    }

    // MARK: endpoints

    struct Endpoint: Hashable {
        enum Kind: Hashable {
            case unixSocket(path: String)
            case tcp(host: String, port: UInt16)
        }
        let kind: Kind
        var label: String {
            switch kind {
            case .unixSocket(let path): return "unix:\(path)"
            case .tcp(let host, let port): return "tcp:\(host):\(port)"
            }
        }
    }

    /// The fallback ladder: on macOS, try the dev then the release Unix socket (fastest, no
    /// per-connection sandbox/firewall concern beyond file permissions), then loopback TCP dev/release
    /// (reachable even from inside a container that can't see the socket path), then — ONLY when this
    /// process is itself running inside a macOS VM (`kern.hv_vmm_present`) — the host's vmnet gateway
    /// address on both TCP ports (`DevKitIngress` binds every `bridge*` interface for exactly this),
    /// then an optional LAN target. On iOS a Unix-socket path means nothing (this app and AgentPad are
    /// different processes on different filesystems even in the Simulator), so only loopback TCP
    /// (which the Simulator forwards to the host) + the LAN override apply — a real device needs
    /// `AGENTPAD_DEVKIT_HOST` to reach a Mac at all.
    static func candidateEndpoints() -> [Endpoint] {
        var out: [Endpoint] = []
        #if os(macOS)
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = support.appendingPathComponent("AgentPad", isDirectory: true)
            out.append(Endpoint(kind: .unixSocket(path: dir.appendingPathComponent(DevKit.devSocketName).path)))
            out.append(Endpoint(kind: .unixSocket(path: dir.appendingPathComponent(DevKit.releaseSocketName).path)))
        }
        #endif
        out.append(Endpoint(kind: .tcp(host: "127.0.0.1", port: DevKit.devTCPPort)))
        out.append(Endpoint(kind: .tcp(host: "127.0.0.1", port: DevKit.releaseTCPPort)))
        #if os(macOS)
        if isRunningInsideVM(), let gateway = defaultGatewayAddress() {
            out.append(Endpoint(kind: .tcp(host: gateway, port: DevKit.devTCPPort)))
            out.append(Endpoint(kind: .tcp(host: gateway, port: DevKit.releaseTCPPort)))
        }
        #endif
        if let lan = ProcessInfo.processInfo.environment[DevKit.lanHostEnvVar] {
            let parts = lan.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let port = UInt16(parts[1]) {
                out.append(Endpoint(kind: .tcp(host: String(parts[0]), port: port)))
            }
        }
        return out
    }

    #if os(macOS)
    /// True when this process is running inside a macOS VM guest (as opposed to bare hardware) — the
    /// documented sysctl for it.
    private static func isRunningInsideVM() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 else { return false }
        return value != 0
    }

    /// This guest's default gateway (the vmnet NAT address, e.g. `192.168.64.1`) — shells out to
    /// `route -n get default` and reads its `gateway:` line, the simplest reliable way to get it
    /// without hand-parsing `PF_ROUTE` socket messages. Best-effort: an App-Sandboxed caller can't
    /// spawn a process at all, in which case this just returns nil and the ladder falls back to
    /// whatever else is reachable (loopback, plus a LAN override if one's set).
    private static func defaultGatewayAddress() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/route")
        proc.arguments = ["-n", "get", "default"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gateway:") else { continue }
            let address = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
            return address.isEmpty ? nil : address
        }
        return nil
    }
    #endif

    // MARK: identity claim (one live connection per logical server, across all reachable transports)

    fileprivate func tryClaim(identityKey: String, endpointLabel: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let holder = claimedBy[identityKey], holder != endpointLabel { return false }
        claimedBy[identityKey] = endpointLabel
        return true
    }
    fileprivate func release(identityKey: String, endpointLabel: String) {
        lock.lock()
        if claimedBy[identityKey] == endpointLabel { claimedBy.removeValue(forKey: identityKey) }
        lock.unlock()
    }

    // MARK: fan-out to every live (claimed) session

    private func broadcastWidgets() {
        let json = dev.specsArrayJSON()
        lock.lock(); let all = Array(sessions.values); lock.unlock()
        all.forEach { $0.sendWidgets(json) }
    }
    private func broadcastValue(_ widgetId: String, _ json: String) {
        lock.lock(); let all = Array(sessions.values); lock.unlock()
        all.forEach { $0.sendValue(widgetId: widgetId, json: json) }
    }

    fileprivate func handleCall(tool: String, argsJSON: String, completion: @escaping (String, Bool) -> Void) {
        let args = argsJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        handler.call(tool, arguments: args, completion: completion)
    }
}

// MARK: - one dial-out connection to one endpoint

/// Owns the connect → hello → welcome/claim → seed → receive-loop lifecycle for ONE endpoint, with
/// its own serial queue (so N sessions run fully independently) and its own reconnect backoff.
private final class Session {
    let endpoint: DevKitClient.Endpoint
    private unowned let client: DevKitClient
    private let queue: DispatchQueue

    private var conn: NWConnection?
    private var backoff: TimeInterval = 2
    private var buffer = Data()
    private var identityKey: String?
    private var claimed = false
    private var stopped = false

    init(endpoint: DevKitClient.Endpoint, client: DevKitClient) {
        self.endpoint = endpoint
        self.client = client
        self.queue = DispatchQueue(label: "agentpad.devkit.client.\(endpoint.label)")
    }

    func start() { queue.async { [weak self] in self?.connect() } }
    func stop() {
        stopped = true
        queue.async { [weak self] in self?.teardown() }
    }

    // MARK: connect

    private func connect() {
        guard !stopped else { return }
        let nwEndpoint: NWEndpoint
        switch endpoint.kind {
        case .unixSocket(let path):
            nwEndpoint = .unix(path: path)
        case .tcp(let host, let port):
            guard let p = NWEndpoint.Port(rawValue: port) else { scheduleRetry(); return }
            nwEndpoint = .hostPort(host: NWEndpoint.Host(host), port: p)
        }
        let c = NWConnection(to: nwEndpoint, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] state in self?.queue.async { self?.handleState(state) } }
        c.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            // Don't hello yet — the server welcomes on accept, and the welcome's `sid` decides
            // whether THIS transport wins the claim for that server. Only the winner registers;
            // a hello from a losing transport used to churn the server's registry on its way out.
            receiveLoop()
        case .waiting:
            // "Connection refused" — nothing is listening on this endpoint YET (AgentPad isn't
            // running, or is the other flavor). NWConnection parks in `.waiting` and only re-dials
            // by itself when the PATH changes, which loopback never does — so it would sit here
            // forever and miss AgentPad starting up seconds later. Re-dial on our own backoff
            // instead; that's what makes "AgentPad doesn't need to be running yet" true.
            scheduleRetry()
        case .failed, .cancelled:
            scheduleRetry()
        default:
            break
        }
    }

    // MARK: outbound frames

    private func sendHello() {
        var obj: [String: Any] = [
            "name": AppIdentity.displayName,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "platform": AppIdentity.platform,
            "instance": AppIdentity.instance,
        ]
        if !AppIdentity.bundleID.isEmpty { obj["bundleId"] = AppIdentity.bundleID }
        if AppIdentity.isSimulator { obj["sim"] = true }
        if !AppIdentity.version.isEmpty { obj["version"] = AppIdentity.version }
        if let icon = AppIdentity.iconPNGBase64 { obj["iconPNG"] = icon }
        send(["hello": obj])
    }

    func sendWidgets(_ specsJSON: String) {
        queue.async { [weak self] in
            guard let self, self.claimed else { return }
            self.send(["widgets": ["specsJSON": specsJSON]])
        }
    }
    func sendValue(widgetId: String, json: String) {
        queue.async { [weak self] in
            guard let self, self.claimed else { return }
            self.send(["values": ["widgetId": widgetId, "valuesJSON": json]])
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let conn, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var line = data
        line.append(0x0A)
        conn.send(content: line, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            self?.queue.async { self?.scheduleRetry() }
        })
    }

    // MARK: inbound frames

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty { self.buffer.append(data); self.drainLines() }
                if done || error != nil { self.scheduleRetry(); return }
                self.receiveLoop()
            }
        }
    }

    private func drainLines() {
        while let r = buffer.range(of: Data([0x0A])) {
            let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            if !line.isEmpty { handleLine(line) }
        }
    }

    private func handleLine(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let welcome = obj["welcome"] as? [String: Any] { handleWelcome(welcome); return }
        if let call = obj["call"] as? [String: Any] { handleCall(call); return }
    }

    private func handleWelcome(_ w: [String: Any]) {
        let server = w["server"] as? String ?? "AgentPad"
        let flavor = w["flavor"] as? String ?? "release"
        // Prefer the server's stable per-process id: display names default to "AgentPad" during
        // startup and can change later, which collapsed DIFFERENT servers (this Mac's and a VM
        // host's) into one dedupe key and starved the local registration.
        let key = (w["sid"] as? String).map { "sid|\($0)" } ?? "\(server)|\(flavor)"
        identityKey = key
        guard client.tryClaim(identityKey: key, endpointLabel: endpoint.label) else {
            // Another transport (e.g. the Unix socket) already reaches this SAME server — don't
            // register twice. Back off further out and re-check later, in case that one drops.
            teardown()
            scheduleRetry(minDelay: 15)
            return
        }
        claimed = true
        backoff = 2
        sendHello()   // register only AFTER winning the claim for this server
        let specsJSON = AgentPadDev.shared.specsArrayJSON()
        if specsJSON != "[]" { send(["widgets": ["specsJSON": specsJSON]]) }
        for (widgetId, json) in AgentPadDev.shared.valuesSnapshot() {
            send(["values": ["widgetId": widgetId, "valuesJSON": json]])
        }
    }

    private func handleCall(_ c: [String: Any]) {
        guard let id = (c["id"] as? NSNumber)?.intValue, let tool = c["tool"] as? String else { return }
        let argsJSON = c["argsJSON"] as? String ?? "{}"
        client.handleCall(tool: tool, argsJSON: argsJSON) { [weak self] text, isError in
            self?.queue.async { self?.send(["reply": ["id": id, "resultJSON": text, "isError": isError]]) }
        }
    }

    // MARK: teardown / retry

    /// One retry in flight at a time. A single dead endpoint reports several states that all mean
    /// "re-dial" (`.waiting` can repeat, and `teardown`'s own cancel would re-enter through
    /// `.cancelled`), and letting each one schedule its own would both storm the endpoint and double
    /// the backoff several times per cycle — reaching the 30s cap almost immediately.
    private func scheduleRetry(minDelay: TimeInterval? = nil) {
        guard !stopped, !retryScheduled else { return }
        retryScheduled = true
        teardown()
        let delay = minDelay ?? backoff
        backoff = min(backoff * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.connect()
        }
    }
    private var retryScheduled = false

    private func teardown() {
        if claimed, let key = identityKey { client.release(identityKey: key, endpointLabel: endpoint.label) }
        claimed = false
        // Drop the handler BEFORE cancelling: otherwise the cancel we're about to do reports
        // `.cancelled` straight back into `handleState` and schedules a second retry for the same
        // drop.
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
        buffer.removeAll()
    }
}
