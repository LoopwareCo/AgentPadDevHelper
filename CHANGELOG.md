# Changelog

## 1.0.0 — 2026-08-16

First public release. (Earlier pre-release tags were retired before anyone depended on them —
this is the clean slate.)

- **UI driving, in-process.** `AgentPadDevHelper.start()` lets AgentPad read the app's live view
  tree and act on it: `ui_snapshot`, `ui_find`, `ui_act`, `ui_setvalue`, `ui_inspect`,
  `ui_focus`, `ui_key` (macOS), `ui_shot`.
- **Widgets.** `AgentPadDev.shared.widget(_:title:symbol:)` declares a small live panel in
  AgentPad's inspector; `push(_:_:)` streams values into its `"$name"` bindings; `onControl`
  receives writes when the user moves a control. Rows: `labelValue`, `text`, `gauge`, `bar`,
  `sparkline`, `keyValueGrid`, `button`, and the controls `slider`, `stepper`, `toggle`,
  `segmented`, `textField`, `colorWell`, `fontPicker`. Matching tools: `widgets_list`,
  `widgets_values`, `widget_set`.
- **Dial-out transport, nothing to configure.** The app connects OUT to AgentPad's ingress
  (Unix socket, then loopback TCP, then a VM host's gateway, then `AGENTPAD_DEVKIT_HOST`) and
  reconnects forever, so either process can start first. No Info.plist keys, no
  local-network consent, no entitlements — an App-Sandboxed macOS app needs only
  `com.apple.security.network.client`.
- **Minimum platforms: macOS 12 / iOS 15** — adding the package never forces a deploy-target
  bump.
- **Debug-only by construction.** `start()` compiles to nothing in release builds; the optional
  `startLoopbackDriver(port:)` (a `127.0.0.1`-only HTTP JSON-RPC endpoint for MCP clients other
  than AgentPad) compiles out too.
- `DevHelperPackage` constants (`repositoryURL`, `minimumVersion`) so tooling can name the
  package without hardcoding either.
