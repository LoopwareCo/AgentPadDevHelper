import Foundation

/// Shared constants for the AgentPadDevHelper dial-out transport. Single-sourced here so the SDK's own
/// dial-out client (`DevKitClient`) and the server's ingress (`AgentPadServerCore.DevKitIngress`,
/// which depends on this package) agree on paths/ports without duplicating literals.
public enum DevKit {
    /// The Unix-socket file names AgentPad's ingress listens on, under
    /// `~/Library/Application Support/AgentPad/`. Flavor-split so a dev and a release AgentPad
    /// running on the same Mac each get their own socket.
    public static let devSocketName = "devkit-dev.sock"
    public static let releaseSocketName = "devkit.sock"
    /// Loopback TCP ports the ingress also listens on (for a Simulator, or any client that can't
    /// reach a Unix-socket path outside its sandbox container). Flavor-split like the socket names.
    public static let devTCPPort: UInt16 = 8797
    public static let releaseTCPPort: UInt16 = 8798

    /// Guest-only loopback reverse forward to the owning host server, separate from guest servers.
    public static let guestTCPPort: UInt16 = 8796

    /// `AGENTPAD_DEVKIT_HOST` — an optional extra `"host:port"` dial-out target (a LAN AgentPad, or a
    /// real iOS device reaching a Mac by address) read by `DevKitClient`'s fallback ladder.
    public static let lanHostEnvVar = "AGENTPAD_DEVKIT_HOST"

    /// `AGENTPAD_SESSION` — the AgentPad session that launched this process. The server puts it in
    /// the environment of every agent CLI it spawns (and its `open` shim passes it through), so an
    /// app under development can simply SAY which session it belongs to instead of the server
    /// guessing from which folder its executable happens to sit in. Read by `AppIdentity.sessionTag`
    /// and sent in the dial-out `hello`; the server also reads it straight out of a same-Mac (or
    /// Simulator) process's environment, so an app built against an older SDK is still attributed.
    public static let sessionTagEnvVar = "AGENTPAD_SESSION"
}
