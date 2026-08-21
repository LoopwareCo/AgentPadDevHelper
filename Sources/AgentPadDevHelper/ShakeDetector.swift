import Foundation
#if canImport(UIKit)
import UIKit
import CoreMotion
#endif

/// Decides whether a stream of accelerometer magnitudes is a deliberate shake.
///
/// Split from the sensor so the decision is testable without one — which matters twice over
/// here: the Simulator has no accelerometer at all, and the device this runs on is somebody's
/// phone, not a test rig.
///
/// Readings arrive in g, gravity included, so a phone at rest reads 1.0. A jolt is a sample
/// whose distance from rest clears `threshold`, and a shake is `requiredJolts` of them inside
/// `window`. Two details keep ordinary handling from qualifying: a jolt only counts once the
/// reading has fallen back below the threshold (otherwise ONE long swing through it reads as a
/// whole shake), and after firing nothing fires again until the shaking has actually STOPPED
/// for `restGap` — a shake doesn't end the moment it's recognized, and its tail must not open a
/// second chooser however long the user keeps going.
struct ShakeRecognizer {
    /// How far from rest (1g) a sample must be to count as a jolt. 1.0 → a total of ~2g, which
    /// is well past walking, a pocket, or setting the phone down on a table.
    var threshold: Double = 1.0
    /// Jolts needed, and the span they must land in. A shake runs at roughly 4–6 Hz, so three
    /// within a second is one clear back-and-forth.
    var requiredJolts: Int = 3
    var window: TimeInterval = 1.0
    /// Still time that ends a shake. Longer than the ~0.2s between a shake's own peaks, short
    /// enough that a second, deliberate shake right after the first still counts.
    var restGap: TimeInterval = 0.5

    private var jolts: [TimeInterval] = []
    private var lastJolt: TimeInterval?
    private var armed = true
    private var cooling = false

    /// Feed one sample; `true` exactly once per shake.
    mutating func ingest(magnitude: Double, at time: TimeInterval) -> Bool {
        guard abs(magnitude - 1.0) > threshold else {
            armed = true
            if cooling, let lastJolt, time - lastJolt > restGap { cooling = false }
            return false
        }
        lastJolt = time
        guard armed else { return false }
        armed = false
        guard !cooling else { return false }

        jolts.removeAll { time - $0 > window }
        jolts.append(time)
        guard jolts.count >= requiredJolts else { return false }
        jolts.removeAll()
        cooling = true
        return true
    }
}

#if canImport(UIKit)

/// Shake-to-open, the iOS way into the feedback chooser.
///
/// CoreMotion rather than UIKit's `motionEnded(_:with:)`: those events go to the first responder
/// and up the host app's OWN responder chain, which an embedded SDK can't join without
/// subclassing the host's window or swizzling UIResponder. The accelerometer belongs to nobody,
/// needs no authorization and no Info.plist key, and — unlike the status-bar band this replaced —
/// there is no system UI to lose the gesture to.
///
/// Sampled at 30 Hz and only while the app is foreground-active; CoreMotion stops delivering in
/// the background anyway, and leaving the sensor running there is how an SDK earns a reputation.
/// `isAccelerometerAvailable` is false in the Simulator, so this is simply inert there — use
/// `AgentPadDevHelper.showUIFeedbackChooser()` to exercise the UI on one.
final class ShakeDetector {
    static let shared = ShakeDetector()
    private init() {}

    /// Called on the MAIN queue.
    var onShake: (() -> Void)?

    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "AgentPadDevHelper.shake"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var recognizer = ShakeRecognizer()
    private var observers: [NSObjectProtocol] = []
    private var installed = false

    /// Idempotent. Starts sampling if the app is already active, and follows it in and out of
    /// the foreground from then on.
    func start() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.resume()
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.suspend()
        })
        if UIApplication.shared.applicationState == .active { resume() }
        #if targetEnvironment(simulator)
        Self.installMotionEventFallback()
        #endif
    }

    private func resume() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        recognizer = ShakeRecognizer()
        motion.accelerometerUpdateInterval = 1.0 / 30.0
        motion.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            let a = data.acceleration
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            guard self.recognizer.ingest(magnitude: magnitude, at: data.timestamp) else { return }
            DispatchQueue.main.async { self.onShake?() }
        }
    }

    private func suspend() {
        guard motion.isAccelerometerActive else { return }
        motion.stopAccelerometerUpdates()
    }

    #if targetEnvironment(simulator)

    /// Simulator ▸ Device ▸ Shake (⌃⌘Z) doesn't move any accelerometer — there isn't one. It
    /// posts a UIKit motion event, which travels the host app's OWN responder chain (first
    /// responder → … → window → `UIApplication` → app delegate) and so is out of reach of an
    /// embedded SDK unless it puts itself in that chain.
    ///
    /// So on a SIMULATOR ONLY, install an implementation of `motionEnded(_:with:)` on
    /// `UIApplication` — the END of the chain, which means a host app that handles shakes itself
    /// (shake-to-undo in a text field, say) still wins, and we only see what nobody wanted. The
    /// original implementation is kept and always called, so nothing is taken away.
    ///
    /// `#if targetEnvironment(simulator)` is doing real work here: rewriting a UIKit class's
    /// method table inside somebody else's app is not something to ship, and this is exactly the
    /// environment — and the only one — where CoreMotion can't do the job.
    private static var motionHookInstalled = false
    private static var originalMotionEnded: IMP?

    private typealias MotionEndedIMP = @convention(c) (AnyObject, Selector, UIEvent.EventSubtype, UIEvent?) -> Void

    private static func installMotionEventFallback() {
        guard !motionHookInstalled else { return }
        let selector = #selector(UIResponder.motionEnded(_:with:))
        let cls: AnyClass = UIApplication.self
        // Inherited from UIResponder when UIApplication doesn't override it — either way this is
        // the implementation that must still run after ours.
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        motionHookInstalled = true

        let hook: @convention(block) (AnyObject, UIEvent.EventSubtype, UIEvent?) -> Void = { app, subtype, event in
            if subtype == .motionShake { ShakeDetector.shared.onShake?() }
            if let original = originalMotionEnded {
                unsafeBitCast(original, to: MotionEndedIMP.self)(app, selector, subtype, event)
            }
        }
        let replacement = imp_implementationWithBlock(hook)
        originalMotionEnded = method_getImplementation(method)
        // Adding fails iff UIApplication implements it ITSELF (rather than inheriting), in which
        // case swap the implementation instead and keep what was there.
        if !class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)) {
            originalMotionEnded = method_setImplementation(method, replacement)
        }
    }

    #endif
}

#endif
