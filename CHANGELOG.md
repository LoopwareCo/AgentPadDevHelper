# Changelog

## 1.0.1 — 2026-08-15

Widgets, and a transport that needs no permission. **This changes how `start()` behaves** — see
Removed before upgrading.

### Added
- **Widgets.** `AgentPadDev.shared.widget(_:title:symbol:)` declares a small live panel in
  AgentPad's inspector; `push(_:_:)` streams values into its `"$name"` bindings; `onControl`
  receives writes when the user moves a control. Rows: `labelValue`, `text`, `gauge`, `bar`,
  `sparkline`, `keyValueGrid`, `button`, and the controls `slider`, `stepper`, `toggle`,
  `segmented`, `textField`, `colorWell`, `fontPicker`. Three matching tools —
  `widgets_list`, `widgets_values`, `widget_set`.
- `AgentPadDevHelper.startLoopbackDriver(port:)` — an optional `127.0.0.1`-only HTTP JSON-RPC
  endpoint serving the same tools, for MCP clients other than AgentPad.

### Changed
- **The app now DIALS OUT to AgentPad instead of hosting a listener.** It connects to AgentPad's
  ingress (Unix socket, then loopback TCP, then a VM host's gateway, then `AGENTPAD_DEVKIT_HOST`)
  and reconnects forever, so either process can start first.
- **No Info.plist edits.** `NSLocalNetworkUsageDescription` and `NSBonjourServices` are no longer
  needed: there's no advertisement and no inbound socket, so there's no local-network consent to
  grant. A sandboxed app needs only `com.apple.security.network.client`.
- Minimum platforms are now **macOS 15 / iOS 18** (were macOS 12 / iOS 15).

### Removed
- **Bonjour advertising, LAN binding and bearer-token auth**, along with `GET /identity.json` and
  `GET /icon.png` and the `_agentpad-dev._tcp` TXT contract. Dialling out replaces discovery, and
  a connection that only ever goes outward over loopback has nothing to authenticate.
  Consequence: **a real device can no longer be driven from another machine.** The app must run on
  the same Mac as AgentPad — natively, in a Simulator, or in a macOS VM on it.
- The constants that hung off `AgentPadDevHelper` (`defaultPort`, `bonjourServiceType`, `mcpPath`,
  `identityMarker`, `instanceID`, `TXT.*`, `toolCatalog`). The transport constants that remain live
  on `DevKit` (`devTCPPort`, `releaseTCPPort`, `devSocketName`, `releaseSocketName`,
  `lanHostEnvVar`).
- `start(port:bindLAN:token:advertise:)` still compiles — it's deprecated and its arguments are
  ignored.

## 1.0.0 — 2026-08-13

First public release.

- `AgentPadDevHelper.start()` serves an in-app MCP endpoint over HTTP JSON-RPC, with the
  `ui_snapshot`, `ui_find`, `ui_act`, `ui_setvalue`, `ui_inspect`, `ui_focus`, `ui_key`, and
  `ui_shot` tools.
- Bonjour discovery over `_agentpad-dev._tcp`, plus `GET /identity.json` and `GET /icon.png`
  for discoverers that can reach the endpoint but not see the advertisement.
- Optional bearer-token auth; `bindLAN: false` for a loopback-only listener.
- Debug-only by construction: `start()` compiles to nothing in release builds.

Extracted from the AgentPad monorepo, where it was named `AgentPadDevKit`. The module, the
package, and the entry-point type are now all `AgentPadDevHelper`; the `DevKit` constants enum
folded into `AgentPadDevHelper` (`DevKit.defaultPort` → `AgentPadDevHelper.defaultPort`), and
the `/identity.json` marker changed from `{"devkit": "agentpad-devkit"}` to
`{"devhelper": "agentpad-devhelper"}`.
