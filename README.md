# AgentPadDevHelper

**Let an AI agent drive your iOS or macOS app's UI — and read live values out of it — in-process,
in one line.**

Add the package, call `AgentPadDevHelper.start()` in a debug build, and your app connects itself
to [AgentPad](https://loopware.com/agentpad): an agent can then read your live view tree, tap
controls, set fields and screenshot windows, and your app can publish **widgets** — small live
panels in AgentPad's inspector — that stream real values out of the running app and take control
writes back.

No Accessibility grant. No synthetic events. No entitlements. No local-network prompt. No
dependencies.

```
[0] window "Inbox"
  [1] button "Compose" @32,64
  [2] table
    [3] cell "Lunch tomorrow?" ="Sarah Chen"
    [4] cell "Re: the build" ="CI Bot"
  [5] textField "Search" ="" #search-field @180,24
```

That's `ui_snapshot` output — the whole UI as ~40 tokens instead of a screenshot.

---

## Install

**Xcode:** File ▸ Add Package Dependencies… → paste the repo URL → add
`AgentPadDevHelper` to your app target.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/LoopwareCo/AgentPadDevHelper", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["AgentPadDevHelper"]),
]
```

Requires Swift 5.9+, macOS 12+, iOS 15+ — no deploy-target bump for any realistic project.

## Use

One line, wherever your app finishes launching:

```swift
import AgentPadDevHelper

// UIKit — AppDelegate
func application(_ app: UIApplication,
                 didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    AgentPadDevHelper.start()
    return true
}

// SwiftUI
@main struct MyApp: App {
    init() { AgentPadDevHelper.start() }
    var body: some Scene { WindowGroup { ContentView() } }
}

// AppKit — NSApplicationDelegate
func applicationDidFinishLaunching(_ note: Notification) {
    AgentPadDevHelper.start()
}
```

You do **not** need to wrap this in `#if DEBUG` — `start()` compiles to nothing in release
builds (see [Safety](#safety)).

There is nothing to configure. Your app **dials out** to any AgentPad on the machine and
reconnects for as long as it runs, so AgentPad doesn't have to be running first — start either
one in either order.

> `start(port:bindLAN:token:advertise:)` still exists for source compatibility with an earlier
> hosted-listener design, but its arguments are **ignored**: the app no longer hosts a listener,
> so there's no port to bind and nothing to advertise.

### No Info.plist edits

An in-app listener would need `NSLocalNetworkUsageDescription` + `NSBonjourServices` to be
discoverable. Dialling out needs neither — there's no advertisement and no inbound socket, so
there's no local-network consent to grant and nothing for the OS to filter.

## Widgets — live values out of your app

Declare a widget once; push values whenever they change. It appears in AgentPad's inspector
beside the session driving your app.

```swift
import AgentPadDevHelper

AgentPadDev.shared.widget("render", title: "Renderer", symbol: "waveform") { w in
    w.labelValue("Scene", "$scene")
    w.bar("FPS", "$fps", max: 120)
    w.sparkline("Frame time", "$history")
    w.slider("Exposure", key: "exposure", min: 0, max: 2)
}

// …then, as your app runs:
AgentPadDev.shared.push("render", ["scene": name, "fps": fps, "history": recentFrameTimes])

// …and take control writes back:
AgentPadDev.shared.onControl = { widgetId, key, value in
    if key == "exposure" { renderer.exposure = value.double ?? 1 }
}
```

A `"$name"` string is a **binding** resolved against whatever you last pushed; anything else is
a literal. Rows available on the builder: `labelValue`, `text`, `gauge`, `bar`, `sparkline`,
`keyValueGrid`, `button`, plus the controls `slider`, `stepper`, `toggle`, `segmented`,
`textField`, `colorWell`, `fontPicker`. Controls are the write path — moving one calls
`onControl` with the new value.

## Connecting

**From AgentPad** — your app appears in the Connected Apps bar automatically, including apps
running in a Simulator or inside a macOS VM. Nothing to configure on either side.

**From another MCP client** (Claude Code, `curl`, your own script) — start the loopback endpoint
as well and point the client at it:

```swift
#if DEBUG
AgentPadDevHelper.startLoopbackDriver(port: 8799)
#endif
```

```sh
claude mcp add --transport http myapp http://127.0.0.1:8799/mcp
```

It serves the same `ui_*` tools over plain HTTP JSON-RPC, **loopback only** — no Bonjour, no
LAN binding, no token. Running two apps side by side? Give each its own port.

## Tools

| Tool | What it does |
| --- | --- |
| `ui_snapshot` | The live view tree as compact text: `[ref] role "label" ="value" #id @x,y` |
| `ui_find` | Same, filtered by `role` and/or `label` substring — fewest tokens |
| `ui_act` | Activate an element by `ref` (tap a button, select a row, toggle a switch) |
| `ui_setvalue` | Set a text field/view's value by `ref`, firing its change handlers |
| `ui_inspect` | One element's role, label, value, and available actions |
| `ui_read` | A subtree's (or the whole app's) visible text in reading order — the prose view |
| `ui_focus` | Which view holds keyboard focus, and whether it's an editable text editor |
| `ui_key` | Type real key events into the app's own event queue — **macOS only** |
| `ui_shot` | Write a PNG of one of the app's windows |
| `review_mode` | Enter/leave **Review UI Mode**: an in-app floating bar where the user taps UI elements and leaves feedback that lands back in AgentPad's UI Feedback Inbox |
| `feedback_chooser` | Raise the UI-feedback chooser — **iOS only**. `via: "motion"` posts a real `motionShake` instead, exercising the same path Simulator ▸ Device ▸ Shake uses |
| `widgets_list` | The widgets this app has declared |
| `widgets_values` | The current values behind a widget's bindings |
| `widget_set` | Write a control's value, as if the user moved it |

`ui_snapshot` and `ui_find` hand you `[ref]` integers; every other `ui_*` tool takes one. Refs
are stable within a snapshot — re-snapshot after the UI changes.

`ui_shot` works because the app draws *itself* into a bitmap, so it needs **no Screen Recording
grant** — it's how you look at your UI from a context where `screencapture` is refused.

`ui_key` targets no element on purpose: `ui_setvalue` proves a field *can* hold text, `ui_key`
proves a keystroke actually *lands* there. Pair it with `ui_focus` to test focus routing. UIKit
has no way to post into its own event queue, so on iOS it returns an error pointing at
`ui_setvalue`.

## Why in-process

Driving another app from outside means system Accessibility plus synthetic events — a
permission dance on macOS and outright impossible on iOS, where the sandbox forbids cross-app
automation.

But to drive *your own* app you need none of it. `AgentPadDevHelper` walks your own view
hierarchy and calls your real handlers directly. That's both possible on iOS *and* more
reliable than faking taps: no hit-testing, no coordinate math, no waiting for animations to
settle before a tap lands somewhere unintended.

It also means an agent reads your UI as **structure** rather than pixels — usually 10–100×
fewer tokens than a screenshot, and it can act on what it read without guessing coordinates.

## Safety

This is a UI-control endpoint. It is **debug-only by design**:

- `start()` is wrapped in `#if DEBUG` inside the package — in a release build it compiles to an
  empty function. There is no flag that turns it on in release.
- It only ever connects **outward, over loopback**, to an AgentPad on the same machine. It opens
  no port, accepts no inbound connection, and is not reachable from the network.
- `startLoopbackDriver(port:)` is the one thing that does listen. It binds `127.0.0.1` only, and
  it too compiles out of release builds.

**Never ship it enabled.**

## How the dial-out works

For anyone writing their own client or debugging a connection:

- The app connects to AgentPad's ingress, trying each in turn and reconnecting forever with
  2s→30s backoff: the Unix sockets `~/Library/Application Support/AgentPad/devkit[-dev].sock`,
  then loopback TCP `127.0.0.1:8797` (dev) and `:8798` (release), then — only when the app is
  itself inside a macOS VM — the host's gateway address on those ports, then `AGENTPAD_DEVKIT_HOST`
  (`host:port`) if you set it.
- It connects to **every** reachable ingress at once, so a dev and a release AgentPad both see
  the app, and dedupes by the server identity in the welcome frame so one logical server gets one
  registration.
- The protocol is newline-delimited JSON: the app sends `hello` (name, bundle id, pid, platform,
  simulator flag, version, icon), then `widgets`/`values` pushes and `reply` frames; AgentPad
  sends `welcome` and `call`.

## Troubleshooting

**App doesn't appear in AgentPad.** Confirm you're running a **Debug** build — `start()` is
compiled out of Release. Both processes must be on the same machine (or the app inside a VM /
Simulator on that machine).

**It appeared, then vanished.** The row tracks the connection: the app quitting, or being
terminated between agent turns, drops it. Relaunch and it reconnects on its own.

**A widget shows em-dashes.** Its bindings have no values yet — call
`AgentPadDev.shared.push(...)` with the keys the spec references.

**`ui_act` returns ok but nothing changed.** The element's real handler ran but did nothing —
check that the control has a target/action or `accessibilityActivate()` support. Use
`ui_inspect` to see which actions an element reports.

**A modal blocks everything.** It shouldn't: tool calls are scheduled as run-loop blocks in the
modal and tracking modes, so an `ui_act` that opens an `NSAlert` doesn't deadlock the calls that
follow it — the next `ui_snapshot` sees the alert's own buttons.

## License

MIT — see [LICENSE](LICENSE).
