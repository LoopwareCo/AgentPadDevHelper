import Foundation
#if canImport(UIKit)
import UIKit          // RunLoop.Mode.tracking
#elseif canImport(AppKit)
import AppKit         // RunLoop.Mode.modalPanel / .eventTracking
#endif

/// Maps an MCP `tools/call` to the in-process `UIDriver`, hopping to the main thread (UIKit /
/// AppKit must be touched there) and replying asynchronously like the macOS relay does.
final class DevToolHandler {
    private let driver = UIDriver()

    /// Run a tool; `completion(text, isError)` is invoked once, on the main thread.
    func call(_ name: String, arguments: [String: Any], completion: @escaping (_ text: String, _ isError: Bool) -> Void) {
        onMain {
            switch name {
            case "ui_snapshot":
                completion(self.driver.snapshot(maxDepth: arguments["maxDepth"] as? Int ?? 16), false)
            case "ui_find":
                completion(self.driver.find(role: arguments["role"] as? String, label: arguments["label"] as? String), false)
            case "ui_act":
                guard let ref = arguments["ref"] as? Int else { return completion("ERROR: missing 'ref'.", true) }
                let r = self.driver.act(ref: ref, action: arguments["action"] as? String)
                completion(r, r.hasPrefix("ERROR"))
            case "ui_setvalue":
                guard let ref = arguments["ref"] as? Int, let text = arguments["text"] as? String else {
                    return completion("ERROR: missing 'ref'/'text'.", true)
                }
                let r = self.driver.setValue(ref: ref, text: text)
                completion(r, r.hasPrefix("ERROR"))
            case "ui_inspect":
                guard let ref = arguments["ref"] as? Int else { return completion("ERROR: missing 'ref'.", true) }
                let r = self.driver.inspect(ref: ref)
                completion(r, r.hasPrefix("ERROR"))
            case "ui_read":
                let r = self.driver.readText(ref: arguments["ref"] as? Int,
                                             maxChars: arguments["maxChars"] as? Int ?? 12000)
                completion(r, r.hasPrefix("ERROR"))
            case "ui_focus":
                completion(self.driver.focus(), false)
            case "ui_key":
                guard let text = arguments["text"] as? String else { return completion("ERROR: missing 'text'.", true) }
                let r = self.driver.key(text: text, window: arguments["window"] as? String)
                completion(r, r.hasPrefix("ERROR"))
            case "ui_shot":
                guard let path = arguments["path"] as? String else { return completion("ERROR: missing 'path'.", true) }
                let r = self.driver.shot(path: path, window: arguments["window"] as? String)
                completion(r, r.hasPrefix("ERROR"))
            case "review_mode":
                // AgentPad's Connected Apps bar flipping Review UI Mode on/off. `setActive`
                // reports back through the `reviewMode` frame either way; a repeat is a no-op.
                let enabled = arguments["enabled"] as? Bool ?? true
                ReviewModeController.shared.setActive(enabled)
                completion("ok: review mode \(enabled ? "on" : "off")", false)
            case "widgets_list":
                completion(AgentPadDev.shared.widgetsListJSON(), false)
            case "widgets_values":
                completion(AgentPadDev.shared.widgetsValuesJSON(), false)
            case "widget_set":
                guard let widgetId = arguments["widgetId"] as? String, let key = arguments["key"] as? String,
                      let value = arguments["value"] else { return completion("ERROR: missing 'widgetId'/'key'/'value'.", true) }
                let ok = AgentPadDev.shared.applyControl(widgetId: widgetId, key: key, rawValue: value)
                completion(ok ? "set \(widgetId).\(key)" : "set \(widgetId).\(key) (no onControl handler)", false)
            default:
                completion("ERROR: unknown tool '\(name)'.", true)
            }
        }
    }

    /// Hop to the main thread as a RUN-LOOP block rather than a `DispatchQueue.main.async` one.
    /// The difference matters whenever an action puts up a modal (an `NSAlert.runModal`, a sheet,
    /// a menu): the main queue is serial, so the still-unfinished `ui_act` that opened the alert
    /// would block every later tool call — the driver could open a dialog but never see or dismiss
    /// it. A run-loop block scheduled in the modal/tracking modes runs inside that nested loop, so
    /// the next `ui_snapshot`/`ui_act` reaches the alert's own buttons.
    private func onMain(_ work: @escaping () -> Void) {
        RunLoop.main.perform(inModes: Self.mainModes, block: work)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// `.common` plus the modes AppKit/UIKit push for modals and tracking loops (menus, drags),
    /// which aren't always common modes.
    private static let mainModes: [RunLoop.Mode] = {
        #if canImport(UIKit)
        return [.common, .tracking]
        #else
        return [.common, .modalPanel, .eventTracking]
        #endif
    }()
}
