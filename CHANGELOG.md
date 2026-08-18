# Changelog

## Unreleased

- **SwiftUI and macOS 26+ toolbar items are now drivable (macOS).** The `ui_*` driver used to
  walk only the NSView tree, which SwiftUI controls (and, from macOS 26 on, the SwiftUI-rendered
  internals of AppKit toolbar items) never appear in. The driver now materializes the app's
  accessibility tree in-process (the same `AXEnhancedUserInterface` flag VoiceOver sets — no
  system Accessibility grant, sandbox-safe) and grafts the AX-only elements into the walk:
  SwiftUI buttons/toggles/fields under an `NSHostingView` show up in `ui_snapshot`/`ui_find`
  with their labels and can be driven with `ui_act`/`ui_setvalue`, and toolbar items read as
  `button "Label"` and activate via their AX press. Note: the flag stays on for the process
  lifetime (dev builds only) and can subtly change window animation behavior in some apps.

First public release. (Earlier pre-release tags were retired before anyone depended on them —
this is the clean slate.)

- **UI driving, in-process.** `AgentPadDevHelper.start()` lets AgentPad read the app's live view
  tree and act on it: `ui_snapshot`, `ui_read`, `ui_find`, `ui_act`, `ui_setvalue`, `ui_inspect`,
  `ui_focus`, `ui_key` (macOS), `ui_shot`.
- **Widgets.** `AgentPadDev.shared.widget(_:title:symbol:)` declares a small live panel in
  AgentPad's inspector; `push(_:_:)` streams values into its `"$name"` bindings; `onControl`
  receives writes when the user moves a control. Rows: `labelValue`, `text`, `gauge`, `bar`,
  `sparkline`, `keyValueGrid`, `button`, and the controls `slider`, `stepper`, `toggle`,
  `segmented`, `textField`, `colorWell`, `fontPicker`. Matching tools: `widgets_list`,
  `widgets_values`, `widget_set`.
- **Review UI Mode.** AgentPad can flip the app into a review mode (`review_mode` tool, or the
  Connected Apps bar's "Review UI" button): a floating AgentPad bar appears — above the Dock on
  macOS, as a status-bar strip + compose card on iOS — where the user types feedback about the
  UI they're looking at, or hits **Choose UI** and clicks/press-holds an element to attach it
  (full ancestor path back to the window root, with frames). Feedback rides the dial-out
  connection into AgentPad's UI Feedback Inbox. Public payload types: `FeedbackPayload`,
  `FeedbackElementDescriptor`, `FeedbackElementNode`.
- **Dial-out transport, nothing to configure.** The app connects OUT to AgentPad's ingress
  (Unix socket, then loopback TCP, then a VM host's gateway, then `AGENTPAD_DEVKIT_HOST`) and
  reconnects forever, so either process can start first. No Info.plist keys, no
  local-network consent, no entitlements — an App-Sandboxed macOS app needs only
  `com.apple.security.network.client`. An app running inside a macOS VM says so when it
  connects (and reports the guest's own address), so AgentPad lists it under the session
  whose VM it's in rather than under every session.
- **Minimum platforms: macOS 12 / iOS 15** — adding the package never forces a deploy-target
  bump.
- **Debug-only by construction.** `start()` compiles to nothing in release builds; the optional
  `startLoopbackDriver(port:)` (a `127.0.0.1`-only HTTP JSON-RPC endpoint for MCP clients other
  than AgentPad) compiles out too.
- `DevHelperPackage` constants (`repositoryURL`, `minimumVersion`) so tooling can name the
  package without hardcoding either.
