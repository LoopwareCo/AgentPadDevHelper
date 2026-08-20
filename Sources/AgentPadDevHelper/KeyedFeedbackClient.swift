import Foundation
import Network
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The app-key transport (`enableUIFeedback(.appKey("apk_…"))`): finds the developer's OWN
/// AgentPad on the local network via Bonjour (`DevKit.appsServiceType` — the server advertises
/// it only while it has app keys) and drains the feedback outbox to it, one item per ack.
///
/// Feedback-only and connect-on-demand: it browses/dials only while there's something to send,
/// disconnects when the outbox is empty, and never handles `call` frames — a build carrying
/// this key can push inbox items and nothing else. Frames are the DevKit line protocol, sealed:
/// the server's plaintext `challenge` nonce + the key's secret derive a per-connection
/// ChaChaPoly key (HKDF-SHA256, info `DevKit.feedbackSealInfo`); the first sealed frame out is
/// `hello`, and the sealed `welcome` back is what proves this server actually holds the key
/// (a wrong server can't unseal, answers nothing, and gets dropped by its own hello gate).
///
/// The HOST app must declare `NSLocalNetworkUsageDescription` and `NSBonjourServices`
/// (`_agentpad-apps._tcp`) in its Info.plist; a denied Local Network prompt means the browse
/// never resolves and items simply wait on the device.
final class KeyedFeedbackClient {
    static let shared = KeyedFeedbackClient()
    private init() {}

    private let queue = DispatchQueue(label: "agentpad.devhelper.keyed-feedback")
    private var keyID = ""
    private var secret = ""
    private var started = false

    private var browser: NWBrowser?
    private var attempt: Attempt?              // one dial at a time, cycling through results
    private var candidates: [NWEndpoint] = []  // discovered, not yet tried this round
    private var retryScheduled = false

    /// `apk_<keyId>_<secret>` → (keyId, secret); shape shared with the server's `AppKeyStore`.
    static func parse(fullKey: String) -> (keyID: String, secret: String)? {
        let parts = fullKey.split(separator: "_", maxSplits: 2)
        guard parts.count == 3, parts[0] == "apk", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    func start(fullKey: String) {
        guard let parsed = Self.parse(fullKey: fullKey) else {
            NSLog("AgentPadDevHelper: enableUIFeedback(.appKey) — key doesn't look like apk_<id>_<secret>; feedback will stay local")
            return
        }
        queue.async { [self] in
            guard !started else { return }
            started = true
            keyID = parsed.keyID
            secret = parsed.secret
            NotificationCenter.default.addObserver(forName: FeedbackOutbox.didChangeNotification,
                                                   object: FeedbackOutbox.shared, queue: nil) { [weak self] _ in
                self?.queue.async { self?.kick() }
            }
            #if canImport(UIKit)
            // A backgrounded app's sockets die quietly; whatever was captured on the go syncs
            // on the next foreground.
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.kick() }
            }
            #endif
            kick()
        }
    }

    // MARK: - on-demand lifecycle (queue-confined)

    /// Something changed (item added/removed, app foregrounded): browse + dial if there's work,
    /// wind down if there isn't.
    private func kick() {
        guard started else { return }
        guard FeedbackOutbox.shared.count() > 0 else {
            stopBrowsing()
            return
        }
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: DevKit.appsServiceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.queue.async {
                guard let self else { return }
                self.candidates = results.map(\.endpoint)
                self.dialNextCandidateIfIdle()
            }
        }
        // A browse can FAIL outright — most commonly a denied Local Network prompt, or a host
        // app that never declared `_agentpad-apps._tcp` in NSBonjourServices. Without this the
        // dead browser stayed non-nil forever and `kick()`'s guard made the process never try
        // again, so granting permission later would still never sync. Drop it and re-browse on
        // the retry clock instead.
        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async {
                    self.browser?.cancel()
                    self.browser = nil
                    self.candidates = []
                    self.scheduleRetryIfNeeded()
                }
            default:
                break
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        candidates = []
        attempt?.close()
        attempt = nil
    }

    private func dialNextCandidateIfIdle() {
        guard attempt == nil, !candidates.isEmpty, FeedbackOutbox.shared.count() > 0 else { return }
        let endpoint = candidates.removeFirst()
        let a = Attempt(endpoint: endpoint, keyID: keyID, secret: secret, queue: queue)
        a.onFinished = { [weak self] drained in
            self?.queue.async {
                guard let self else { return }
                self.attempt = nil
                if drained {
                    // Everything acked — wind down until the next capture.
                    self.stopBrowsing()
                } else {
                    // Wrong server / dropped / refused: try the next found endpoint, or wait.
                    self.dialNextCandidateIfIdle()
                    self.scheduleRetryIfNeeded()
                }
            }
        }
        attempt = a
        a.start()
    }

    /// Nothing reachable held our key this round — re-try the round in 60s while work remains
    /// (Bonjour will also re-fire `browseResultsChangedHandler` if the server appears).
    private func scheduleRetryIfNeeded() {
        guard !retryScheduled, attempt == nil, FeedbackOutbox.shared.count() > 0 else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            if let browser = self.browser {
                self.candidates = browser.browseResults.map(\.endpoint)
                self.dialNextCandidateIfIdle()
            } else {
                // The browser died (see the failure handler above) — start a fresh one, which
                // is also how a later Local-Network grant takes effect without an app restart.
                self.kick()
            }
        }
    }

    // MARK: - one dial to one discovered endpoint

    private final class Attempt {
        private let endpoint: NWEndpoint
        private let keyID: String
        private let secret: String
        private let queue: DispatchQueue
        /// true = the outbox is fully drained; false = try elsewhere.
        var onFinished: ((Bool) -> Void)?

        private var conn: NWConnection?
        private var sessionKey: SymmetricKey?
        private var welcomed = false
        private var buffer = Data()
        private var pending: [OutboxItem] = []
        private var finished = false
        private var timeout: DispatchWorkItem?

        init(endpoint: NWEndpoint, keyID: String, secret: String, queue: DispatchQueue) {
            self.endpoint = endpoint; self.keyID = keyID; self.secret = secret; self.queue = queue
        }

        func start() {
            let c = NWConnection(to: endpoint, using: .tcp)
            conn = c
            c.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    switch state {
                    case .failed, .cancelled: self?.finish(drained: false)
                    case .waiting: self?.finish(drained: false)   // unreachable — next candidate
                    default: break
                    }
                }
            }
            c.start(queue: queue)
            receiveLoop()
            // The whole handshake (TCP + challenge + welcome) should be sub-second on a LAN.
            scheduleTimeout(10)
        }

        func close() { finish(drained: false) }

        private func finish(drained: Bool) {
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            conn?.stateUpdateHandler = nil
            conn?.cancel()
            conn = nil
            onFinished?(drained)
            onFinished = nil
        }

        private func scheduleTimeout(_ seconds: TimeInterval) {
            timeout?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.finish(drained: false) }
            timeout = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }

        private func receiveLoop() {
            conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self else { return }
                self.queue.async {
                    if let data, !data.isEmpty { self.buffer.append(data); self.drainLines() }
                    if done || error != nil { self.finish(drained: false); return }
                    if !self.finished { self.receiveLoop() }
                }
            }
        }

        private func drainLines() {
            while let r = buffer.range(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                if !line.isEmpty { handleLine(line) }
            }
            if buffer.count > 16_000_000 { finish(drained: false) }
        }

        private func handleLine(_ data: Data) {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            if let challenge = obj["challenge"] as? [String: Any],
               let nonce = (challenge["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                // Derive the per-connection key and introduce ourselves; a server that doesn't
                // hold this key can't read the hello and will drop us at its own hello gate.
                sessionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
                                                    salt: nonce, info: Data(DevKit.feedbackSealInfo.utf8),
                                                    outputByteCount: 32)
                var hello: [String: Any] = [
                    "name": AppIdentity.displayName,
                    "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "platform": AppIdentity.platform,
                    "instance": AppIdentity.instance,
                ]
                if !AppIdentity.bundleID.isEmpty { hello["bundleId"] = AppIdentity.bundleID }
                if AppIdentity.isSimulator { hello["sim"] = true }
                if !AppIdentity.version.isEmpty { hello["version"] = AppIdentity.version }
                sendSealed(["hello": hello])
                return
            }
            guard let sealed = obj["sealed"] as? [String: Any],
                  let box = (sealed["box"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let key = sessionKey,
                  let sealedBox = try? ChaChaPoly.SealedBox(combined: box),
                  let plain = try? ChaChaPoly.open(sealedBox, using: key),
                  let inner = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { return }

            if inner["welcome"] != nil {
                // This server holds our key. Drain, oldest first, one item per ack.
                welcomed = true
                pending = FeedbackOutbox.shared.all()
                sendNextPending()
                return
            }
            if let ack = inner["feedbackAck"] as? [String: Any], let id = ack["id"] as? String {
                FeedbackOutbox.shared.delete(ids: [id])
                sendNextPending()
            }
        }

        private func sendNextPending() {
            guard welcomed else { return }
            guard !pending.isEmpty else {
                // Catch anything captured while this drain ran, then declare victory.
                let remaining = FeedbackOutbox.shared.all()
                if remaining.isEmpty { finish(drained: true) } else { pending = remaining; sendNextPending() }
                return
            }
            let item = pending.removeFirst()
            // The screenshot lives in a sidecar file — attach it only now, for this one frame.
            let full = FeedbackOutbox.shared.fullItem(item)
            guard let payload = try? JSONEncoder().encode(full.payload),
                  let payloadJSON = String(data: payload, encoding: .utf8) else { sendNextPending(); return }
            sendSealed(["feedback": ["payloadJSON": payloadJSON,
                                     "id": item.id,
                                     "capturedAt": WireDate.iso8601.string(from: item.capturedAt)]])
            scheduleTimeout(30)   // per-item: screenshots take a moment on weak WiFi
        }

        private func sendSealed(_ obj: [String: Any]) {
            guard let key = sessionKey, let conn,
                  let plain = try? JSONSerialization.data(withJSONObject: obj),
                  let sealed = try? ChaChaPoly.seal(plain, using: key),
                  let line = try? JSONSerialization.data(withJSONObject:
                    ["sealed": ["keyId": keyID, "box": sealed.combined.base64EncodedString()]]) else { return }
            var out = line
            out.append(0x0A)
            conn.send(content: out, completion: .contentProcessed { _ in })
        }
    }
}
