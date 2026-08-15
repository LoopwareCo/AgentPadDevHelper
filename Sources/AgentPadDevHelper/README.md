# AgentPadDevHelper

Make **any iOS or macOS app drivable by AgentPad** (or any MCP client) with one dependency.

Add the package, call `AgentPadDevHelper.start()` in a debug build, and the app exposes an
in‑app **MCP server** with the same `ui_*` tools the macOS AgentPad agent already drives — so a
model can read your live UI tree and tap controls / set fields by ref, in‑process. No system
Accessibility grant, no synthetic events, no entitlements.

## Why in‑process
The macOS AgentPad agent drives *other* apps out‑of‑process via system Accessibility + CGEvent.
On iOS that's impossible (the sandbox forbids cross‑app automation). But to drive *your own* app
you don't need any of that — `AgentPadDevHelper` walks your own view hierarchy and calls the real
handlers directly, which is both possible on iOS and more reliable than faking taps.

## Install
Swift Package Manager — add `AgentPadKitCore` + `AgentPadDevHelper` (the helper depends on Core;
neither depends on the AgentPad server/app, so your app stays lean).

## Use
```swift
#if DEBUG
import AgentPadDevHelper
// e.g. in application(_:didFinishLaunchingWithOptions:)
AgentPadDevHelper.start()                 // serves http://<host>:8799/mcp + Bonjour _agentpad-dev._tcp
// AgentPadDevHelper.start(bindLAN: false) // Simulator/host loopback only
// AgentPadDevHelper.start(token: "…")     // require an Authorization: Bearer <token>
#endif
```

## Tools (MCP `tools/list`)
- `ui_snapshot` — compact text tree of the live UI: `[ref] role "label" ="value" #id @x,y`
- `ui_find` — filter by `role` / `label` substring
- `ui_act` — activate an element by `ref` (taps a button, selects a row, toggles a switch)
- `ui_setvalue` — set a text field/view's value by `ref` (fires change handlers)
- `ui_inspect` — read one element's role/label/value/actions
- `ui_focus` — which view holds keyboard focus (first responder, and whether it's an editable
  text editor)
- `ui_key` — type real key events into the app's own event queue (macOS only). Targets no
  element: with `ui_focus` it's how you test where a keystroke LANDS, which the in-process
  actions above deliberately bypass.
- `ui_shot` — write a PNG of one of the app's own windows (`path`, optional `window` title
  substring). The app draws itself into a bitmap, so it needs **no Screen Recording grant** — this
  is how you look at a UI change from a session where `screencapture` is refused.

Point any MCP client at `http://<host>:8799/mcp` (HTTP JSON‑RPC, like AgentPad's `BridgeMCP`), or
let AgentPad discover it over Bonjour.

## ⚠️ Safety
This is a UI‑control endpoint, so it is **debug‑only by design**: `start()` is compiled out of
release builds (`#if DEBUG`). In debug it binds the LAN and advertises by default; pass
`bindLAN: false` for loopback-only access. It also supports
an optional bearer token. **Never ship it enabled.**

## Layout
- `AgentPadKitCore` — `UINode` model + compact text renderer + the `ui_*` tool catalog + constants
- `AgentPadDevHelper` — `UIDriver` (UIKit/AppKit in‑process walker + dispatcher), `DevToolHandler`,
  `DevMCPServer` (in‑app HTTP MCP server + Bonjour), `AgentPadDevHelper.start()`
