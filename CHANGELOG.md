# Changelog

## Unreleased

- Review UI is live-only, initiated by AgentPad and bound to its connection/review ID.
- Removed app keys, shipped feedback capture, app-side inbox/export APIs, shake and Help-menu entry points.
- Loopback tools no longer expose review_mode or feedback_chooser.


- **macOS: an app with no icon of its own now reports no icon, instead of the system's.** macOS has
  no "this app has no icon" answer — `NSApplication.applicationIconImage` hands back the generic app
  artwork — so the SDK was telling the server that placeholder WAS the app. It now checks its own
  bundle first (a `CFBundleIconName` asset or a `CFBundleIconFile(s)` resource that actually
  resolves; a key pointing at artwork that was removed doesn't count) and omits `iconPNG` otherwise.
  Such an app shows AgentPad's platform glyph rather than a grey square, and — the reason it
  matters — no longer lends that square to the PROJECT it's running in, where the same placeholder
  every iconless app produces would afterwards read like an icon somebody chose. iOS was already
  correct: with no `AppIcon`, there was never an icon to send.

- **macOS: the Review Mode bar follows the app it belongs to.** It's chrome for ONE app, so it's
  on screen only while that app is frontmost: it hides when the user switches away (including
  the moment the mode is switched on from AgentPad, which is frontmost then) and fades back,
  where they left it, when the app returns. Review Mode itself is untouched by this — the
  server's picture stays "reviewing" throughout, and only Done ends it. Choosing is cancelled on
  the way out, since the hit-test overlay would otherwise be left with no visible way to exit.

- **Review Mode's default attachment is the WINDOW, not the view filling it.** Open the composer
  without choosing anything and the token now reads "Local LLM — window" (the window's title, or
  the app's name for an untitled one) instead of "NSView": the content view most windows hand
  back is an anonymous container, so the chip named nothing to the user and the item shipped a
  one-word `NSView` path to the agent meant to fix it. Choosing an element is unchanged. On iOS
  the title is the top view controller's, as before.

- **A host app can take the "View & Send" entry point over with its own window.**
  `AgentPadDevHelper.setFeedbackReviewHandler(_:)` re-points the Help-menu item (macOS) / the
  chooser's view action (iOS) at the host, which supplies the item's title and a count of the
  feedback IT holds; everything the SDK's own list does is now reachable from outside the
  package: `pendingFeedback()` (each item with a ready-made `FeedbackCardModel`),
  `pendingFeedbackCount()`, `pendingFeedbackDidChange`, `deletePendingFeedback(ids:)`,
  `pendingFeedbackStatusLine()` and `writeFeedbackArchive(ids:extraSections:fileLabel:)`.
  `extraSections` is the point: a host ships its OWN kinds of feedback at the top level of the
  same `.agentpadfeedback` package — written verbatim, never interpreted here, and unable to
  overwrite the SDK's own keys — so an app with several kinds of feedback still has one review
  window, one share file, one send.

- **iOS: shake the device to leave UI feedback — the status-bar triple-tap is gone.** It never
  worked on a real iPhone. Two shipped attempts at that band failed: a recognizer on the app's
  key window, then a transparent window of our own above `.statusBar`. The band is arbitrated by
  the system whatever level a window claims, and on a Dynamic Island phone its middle third is
  system UI outright. The gesture is now read straight off the accelerometer (`ShakeRecognizer`:
  three ~2g jolts inside a second, one chooser per shake) — no authorization, no Info.plist key,
  no touch handling taken away from the host app, and sampling only while the app is
  foreground-active.
- **`AgentPadDevHelper.showUIFeedbackChooser()` (iOS).** Raise the same chooser from the host
  app's own UI — a Settings row, a debug menu.
- **Simulator ▸ Device ▸ Shake (⌃⌘Z) raises the chooser too.** That menu item moves no
  accelerometer — it posts a UIKit motion event down the host app's own responder chain — so on
  a SIMULATOR ONLY the SDK installs `motionEnded(_:with:)` on `UIApplication`, the end of that
  chain. A host app that handles shakes itself still wins, the original implementation is kept
  and always called, and nothing of the sort exists in a build for a real device.
- **`feedback_chooser` driver tool (iOS).** The same chooser over the `ui_*` endpoint, for
  scripts. `{"via":"motion"}` posts a real `motionShake` instead of calling in directly, which is
  the only way to check the responder-chain path from a script — `simctl` cannot shake a device.
- **The review strip's controls moved below the status bar.** Same cause: "+ UI Review" and
  "Done" sat inside the system-owned band, so they drew correctly and could not be pressed on a
  device. The strip now spans the band plus a 44pt control row underneath it.

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
