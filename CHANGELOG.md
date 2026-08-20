# Changelog

## 0.9.0 — 2026-08-19

The first resolvable release. (The retired `1.0.0` tag was withdrawn — the package
versions as 0.9.x until AgentPad itself reaches 1.0; everything below ships in 0.9.0.)

- **In-app UI reviews — `AgentPadDevHelper.enableUIFeedback(.localOnly)`.** Developers (and
  their beta testers) can now leave Review-UI feedback FROM the app, without AgentPad
  activating anything:
  - macOS: an "AgentPad" grouping appears at the end of the app's Help menu — "Leave UI Review
    Feedback…" and "View & Send (N) UI Feedbacks…". (An app with no Help menu gets no menu
    entry.)
  - iOS: TRIPLE-tap the status bar for a chooser (leave feedback / view pending / cancel). The
    review strip is redesigned: gradient over the status bar with "+ UI Review" (left) and
    "Done" (right), and it's now the one strip both activation paths show.
  - Unlike `start()`, `enableUIFeedback` is NOT development-gated — it opens no control
    channel. `.localOnly` never dials out: feedback stays on the device until the user sends
    it via the standard share panel, as one `.agentpadfeedback` file the developer opens in
    AgentPad.
  - `.appKey("apk_…")` — YOUR OWN devices: feedback syncs over the local network to the one
    AgentPad that minted the key (Server Settings → Apps → Add Key). Discovery is Bonjour
    (`_agentpad-apps._tcp`, advertised only while the server holds keys); every frame is
    sealed to the key (HKDF → ChaChaPoly), and the connection is feedback-only by
    construction — a key can add inbox items and nothing else. The host app must declare
    `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_agentpad-apps._tcp`) in its
    Info.plist.
- **Offline-first feedback outbox.** Every submitted review is persisted in the app's own
  container the moment the user hits send, uploaded when a (new enough) AgentPad is reachable,
  and deleted only on the server's acknowledgment — quitting AgentPad, dropped connections, or
  the app crashing mid-send no longer lose feedback. Capped at 200 items, oldest evicted.
- The pending list renders with the same card views AgentPad's UI Feedback Inbox uses
  (`FeedbackCardView` / `FeedbackCardModel`, now public in this package).

### Also in 0.9.0 — the original feature set

- **UI driving, in-process.** `AgentPadDevHelper.start()` lets AgentPad read the app's live view
  tree and act on it: `ui_snapshot`, `ui_read`, `ui_find`, `ui_act`, `ui_setvalue`, `ui_inspect`,
  `ui_focus`, `ui_key` (macOS), `ui_shot`.
- **SwiftUI and macOS 26+ toolbar items are drivable (macOS).** A driver that walked only the
  NSView tree would never see SwiftUI controls (or, from macOS 26 on, the SwiftUI-rendered
  internals of AppKit toolbar items). The driver materializes the app's accessibility tree
  in-process instead (the same `AXEnhancedUserInterface` flag VoiceOver sets — no system
  Accessibility grant, sandbox-safe) and grafts the AX-only elements into the walk: SwiftUI
  buttons/toggles/fields under an `NSHostingView` show up in `ui_snapshot`/`ui_find` with their
  labels and can be driven with `ui_act`/`ui_setvalue`, toolbar items read as `button "Label"`
  and activate via their AX press, and **Choose UI** selects them too. Note: the flag stays on
  for the process lifetime (dev builds only) and can subtly change window animation behavior in
  some apps.
- **iOS alert buttons activate (iOS 26/27).** Alert actions are no longer `UIControl`s and
  `accessibilityActivate()` is a no-op on them, so `ui_act` matches the action by title on the
  owning `UIAlertController`, runs it, and dismisses; the actions list advertises accessibility
  buttons rather than gating on `UIControl`.
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
  than AgentPad) compiles out too. That driver has one deliberate exception:
  `AGENTPAD_DEVKIT_DRIVER_LAN=1` binds it to all interfaces so an app on a REAL iOS device is
  drivable from the development Mac (a device's loopback is unreachable from outside, and the
  dial-out ingress doesn't listen on the LAN). Off unless the launcher passes it, DEBUG-only,
  and never appropriate outside a trusted development network.
- `DevHelperPackage` constants (`repositoryURL`, `minimumVersion`) so tooling can name the
  package without hardcoding either.
