import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Who the host app is, as sent in the dial-out `hello` frame (`DevKitClient`). Identity travels on
/// the wire now instead of a Bonjour TXT record, but the shape is the same: a stable per-process
/// instance id, bundle/platform/version info, and (optionally) the app icon.
///
/// The icon is rasterized ONCE, on the main thread, and cached: AppKit/UIKit image APIs are
/// main-thread work, but `hello` can be sent from a background queue.
enum AppIdentity {
    /// Identifies THIS process's connection. A server that sees the same app dial in twice (e.g. a
    /// dev AND a release AgentPad both reachable) can tell they're the same instance.
    static let instance = UUID().uuidString

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }
    static var displayName: String { UIDriver.appName }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    static var platform: String {
        #if os(macOS)
        return "macos"
        #elseif os(iOS)
        return "ios"
        #else
        return "other"
        #endif
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // MARK: icon

    private static let iconLock = NSLock()
    private static var cachedIcon: Data?
    private static var iconPrepared = false

    /// The cached icon PNG, or nil if there isn't one (or it hasn't been rasterized yet — the
    /// `hello` frame then omits `iconPNG` and the server shows a generic glyph).
    static var iconPNG: Data? {
        iconLock.lock(); defer { iconLock.unlock() }
        return cachedIcon
    }

    /// The icon, base64-encoded for the `hello` frame's `iconPNG` field (nil when there's no icon,
    /// or `prepareIcon()` hasn't run/finished yet).
    static var iconPNGBase64: String? {
        iconPNG?.base64EncodedString()
    }

    /// Rasterize + cache the app icon. Safe to call from any thread; hops to main because it draws.
    static func prepareIcon() {
        iconLock.lock()
        let alreadyDone = iconPrepared
        iconPrepared = true
        iconLock.unlock()
        guard !alreadyDone else { return }
        let render = {
            let png = renderIconPNG()
            iconLock.lock(); cachedIcon = png; iconLock.unlock()
        }
        if Thread.isMainThread { render() } else { DispatchQueue.main.async(execute: render) }
    }

    /// Draw the app icon into a 128×128 PNG. Main thread.
    private static func renderIconPNG() -> Data? {
        let side = 128
        #if canImport(UIKit)
        // iOS keeps the icon in the asset catalog; the Info.plist lists the rendered variants and
        // the last one is the largest.
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        let candidates = files.reversed() + ["AppIcon"]
        guard let image = candidates.lazy.compactMap({ UIImage(named: $0) }).first else { return nil }
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .pngData()
        #elseif canImport(AppKit)
        let image = NSApplication.shared.applicationIconImage
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}
