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
/// SAFETY: this opens a UI-control channel, so it is **debug-only by design** — `start()` is a no-op
/// in release builds (compiled out via `#if DEBUG`). Never ship it enabled.
public enum AgentPadDevHelper {
    private static var started = false

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

    /// Begin dialing out to AgentPad.
    public static func start() {
        #if DEBUG
        guard !started else { return }
        started = true
        DevKitClient.shared.start()
        #endif
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
