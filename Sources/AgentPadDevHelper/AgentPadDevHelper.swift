import Foundation

/// Drop-in: add this package to any iOS or macOS app and call `AgentPadDevHelper.start()` to let
/// AgentPad drive the app's UI in-process — inspect the live view tree and activate controls / set
/// fields by ref, and stream custom inspector Widgets. Reuses the same `ui_*` tools the macOS
/// AgentPad agent drives, so prompts and habits transfer across apps and platforms.
///
/// This app DIALS OUT to AgentPad (`DevKitClient`) rather than hosting anything — sandboxed/
/// Simulator apps can't host a listener, and loopback dial-out is sandbox-safe everywhere. It tries
/// every reachable AgentPad (dev + release, Unix socket + loopback TCP, optional LAN via
/// `AGENTPAD_DEVKIT_HOST`) and reconnects forever — AgentPad doesn't need to be running yet.
///
/// SAFETY: this opens a UI-control channel, so it is **debug-only by design**, and the SDK enforces
/// that itself — call `start()` unconditionally from your app's launch path and don't build a flag
/// around it. Two layers, neither of which you have to remember:
///   1. `start()` is compiled out entirely by `#if DEBUG` — SwiftPM builds this package with your
///      app's configuration, so a Release build has no code to call;
///   2. even in a Debug-configured binary it refuses to open the channel if the app carries any
///      evidence of having been distributed — a TestFlight or App Store receipt, a distribution
///      provisioning profile, or a Developer ID signature (see `BuildTrust`). That covers the case
///      layer 1 can't: a Debug-config archive uploaded to TestFlight.
/// Refusals say why, once, via `NSLog`.
public enum AgentPadDevHelper {
    private static var started = false

    /// What the SDK decided about this build, and why — `.development` when the dial-out is
    /// allowed. Exposed so an app can show its own diagnostics; `start()` applies it for you.
    public static var buildTrust: BuildTrust.Verdict { BuildTrust.current }

    /// Begin dialing out to AgentPad.
    ///
    /// - Parameters are DEPRECATED and ignored: this app no longer hosts a listener, so there is no
    ///   port to bind, no LAN-vs-loopback choice, no token, and nothing to advertise — the dial-out
    ///   ladder (`DevKitClient.candidateEndpoints()`) figures all of that out on its own. Kept only so
    ///   existing call sites (`AgentPadDevHelper.start(port:bindLAN:)`, etc.) keep compiling.
    @available(*, deprecated, message: "port/bindLAN/token/advertise are ignored — the app now dials OUT to AgentPad; nothing to configure")
    public static func start(port: UInt16 = 8799, bindLAN: Bool = true,
                             token: String? = nil, advertise: Bool = true) {
        start()
    }

    /// Begin dialing out to AgentPad. Safe to call unconditionally: it does nothing in a Release
    /// build, and nothing in a build that has been shipped (see the note above).
    public static func start() {
        #if DEBUG
        guard !started else { return }
        if case .shipped(let reason) = BuildTrust.current {
            // Deliberately loud but harmless: a developer who wonders why their app isn't showing
            // up in AgentPad gets told, and a shipped build gets a log line rather than a channel.
            NSLog("AgentPadDevHelper: not starting — \(reason). The UI-control channel only runs in development builds.")
            return
        }
        started = true
        DevKitClient.shared.start()
        // Development builds get the developer entry points too (Help-menu grouping / status-bar
        // triple-tap) — feedback then rides the dial-out connections like everything else.
        FeedbackEntryPoints.shared.install(mode: .debugDialOut)
        #endif
    }

    // MARK: - UI feedback capture (shippable, capture-only)

    /// How feedback captured via `enableUIFeedback` leaves the device.
    public enum UIFeedbackMode {
        /// Feedback ONLY stores on this device; the user decides to share it (the pending list's
        /// share panel writes one `.agentpadfeedback` file the developer opens in AgentPad).
        /// Nothing dials out — safe to ship to beta testers.
        case localOnly
        /// YOUR OWN devices only: feedback syncs over the local network to the ONE AgentPad
        /// that minted this key (Server Settings → Apps → Add Key). Feedback-only — the key
        /// authorizes pushing inbox items, never UI driving. The host app's Info.plist must
        /// declare `NSLocalNetworkUsageDescription` and `NSBonjourServices` with
        /// `_agentpad-apps._tcp`; feedback crosses your WiFi sealed to the key.
        case appKey(String)
    }

    /// Turn on in-app UI reviews: the entry points (macOS: an "AgentPad" grouping at the end of
    /// the Help menu; iOS: triple-tap the status bar) plus the on-device outbox behind them.
    ///
    /// Unlike `start()`, this is NOT development-gated — it opens no control channel. Everything
    /// it enables is user-initiated capture that stays on the device until the user (or, in a
    /// development build, the dial-out sync) moves it. Call it unconditionally, or only for the
    /// builds you want collecting feedback.
    public static func enableUIFeedback(_ mode: UIFeedbackMode = .localOnly) {
        switch mode {
        case .localOnly:
            FeedbackEntryPoints.shared.install(mode: .localOnly)
        case .appKey(let key):
            KeyedFeedbackClient.shared.start(fullKey: key)
            FeedbackEntryPoints.shared.install(mode: .appKey)
        }
    }

    /// Stop every dial-out connection.
    public static func stop() {
        started = false
        DevKitClient.shared.stop()
    }

    #if DEBUG
    /// Begin serving THIS process's own `ui_*`/widget tools over a loopback-only HTTP JSON-RPC
    /// endpoint (`LoopbackDriver`) — the viewer's own self-drive harness, distinct from the dial-out
    /// transport above (which registers this app as a target for OTHER AgentPad instances to drive).
    /// DEBUG-only; a no-op call site in a release build simply never links this in.
    public static func startLoopbackDriver(port: UInt16) {
        LoopbackDriver.shared.start(port: port)
    }
    #endif
}
