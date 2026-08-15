import Foundation
import AgentPadDevHelper

// A stand-in for "an app under development" that embeds AgentPadDevHelper. It declares one widget,
// streams a live signal into it, and applies control writes back — proving the full round-trip:
//   AgentPad inspector  ⇄  this process (dialing OUT to AgentPad's DevKit ingress).
//
// Run:  swift run AgentPadDevSample
// Then open AgentPad (dev or release) — this process finds it automatically (Unix socket or
// loopback TCP, whichever's reachable) and its "Sample App" widget shows up live.

// App state the controls drive.
var speed = 1.0
var paused = false

AgentPadDev.shared.onControl = { widgetId, key, value in
    switch key {
    case "speed": speed = value.double ?? speed
    case "paused": paused = value.bool
    default: break
    }
    print("← \(widgetId).\(key) = \(value.string)   (speed=\(String(format: "%.2f", speed)), paused=\(paused))")
}

AgentPadDev.shared.widget("sample-anim", title: "Sample App", symbol: "app.dashed") { c in
    c.text("Live from a real process via AgentPadDevHelper")
    c.gauge("Signal", "$t", max: 1)
    c.sparkline("History", "$history")
    c.labelValue("Speed", "$speed")
    c.slider("Speed", key: "speed", min: 0, max: 3, step: nil)
    c.toggle("Paused", key: "paused")
    c.fontPicker("Font", key: "font")
    c.colorWell("Tint", key: "tint")
}
AgentPadDev.shared.push("sample-anim", ["speed": speed, "paused": paused, "font": "Menlo", "tint": "#e11d48", "t": 0.0, "history": [Double]()])

AgentPadDevHelper.start()
print("AgentPadDevSample dialing out to AgentPad (dev + release, Unix socket + loopback TCP)…")

var t = 0.0
var history: [Double] = []
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    if !paused { t += 0.05 * speed }
    let v = (sin(t) + 1) / 2
    history.append(v); if history.count > 40 { history.removeFirst() }
    AgentPadDev.shared.push("sample-anim", ["t": v, "history": history, "speed": speed])
}
RunLoop.main.run()
