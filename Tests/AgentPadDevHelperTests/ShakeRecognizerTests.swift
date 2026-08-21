import XCTest
@testable import AgentPadDevHelper

/// The shake that opens the iOS feedback chooser, decided from synthetic accelerometer
/// magnitudes — the device it ships on is somebody's phone and the Simulator has no
/// accelerometer at all, so this is where the thresholds are actually pinned.
final class ShakeRecognizerTests: XCTestCase {

    /// Feed `seconds` of samples at 30 Hz from a generator; returns each time it fired.
    private func run(_ recognizer: inout ShakeRecognizer, seconds: TimeInterval,
                     from start: TimeInterval = 0,
                     magnitude: (TimeInterval) -> Double) -> [TimeInterval] {
        let step = 1.0 / 30.0
        var fired: [TimeInterval] = []
        var t = start
        while t < start + seconds {
            if recognizer.ingest(magnitude: magnitude(t - start), at: t) { fired.append(t) }
            t += step
        }
        return fired
    }

    /// |a| swinging around rest at `hz`, peaking `amplitude` g away from it.
    private func oscillation(hz: Double, amplitude: Double) -> (TimeInterval) -> Double {
        { 1.0 + amplitude * sin(2 * .pi * hz * $0) }
    }

    func testPhoneAtRestNeverFires() {
        var r = ShakeRecognizer()
        XCTAssertTrue(run(&r, seconds: 10) { _ in 1.0 }.isEmpty)
    }

    /// Walking with the phone in hand: real motion, nowhere near 2g.
    func testOrdinaryHandlingNeverFires() {
        var r = ShakeRecognizer()
        XCTAssertTrue(run(&r, seconds: 10, magnitude: oscillation(hz: 2, amplitude: 0.6)).isEmpty)
    }

    func testDeliberateShakeFiresOnce() {
        var r = ShakeRecognizer()
        // One second of a 5 Hz, 1.5g shake — five jolts, well inside the window.
        let fired = run(&r, seconds: 1.0, magnitude: oscillation(hz: 5, amplitude: 1.5))
        XCTAssertEqual(fired.count, 1, "a one-second shake is one chooser, not five")
    }

    /// The shake doesn't stop dead when it's recognized, and a user who keeps going for a while
    /// still means one chooser — however long "a while" turns out to be.
    func testShakeTailIsSuppressedHoweverLong() {
        for seconds in [2.5, 10.0] {
            var r = ShakeRecognizer()
            let fired = run(&r, seconds: seconds, magnitude: oscillation(hz: 5, amplitude: 1.5))
            XCTAssertEqual(fired.count, 1, "\(seconds)s of shaking")
        }
    }

    /// …but a second, separate shake later does count.
    func testSecondShakeAfterQuietPeriodFires() {
        var r = ShakeRecognizer()
        let shake = oscillation(hz: 5, amplitude: 1.5)
        XCTAssertEqual(run(&r, seconds: 1.0, from: 0, magnitude: shake).count, 1)
        XCTAssertEqual(run(&r, seconds: 1.0, from: 30, magnitude: shake).count, 1)
    }

    /// Two jolts are a bump, not a shake — the count is what separates dropping the phone on a
    /// desk from waving it.
    func testTwoJoltsAreNotAShake() {
        var r = ShakeRecognizer()
        var fired = false
        for (i, magnitude) in [1.0, 3.0, 1.0, 3.0, 1.0].enumerated() {
            fired = fired || r.ingest(magnitude: magnitude, at: Double(i) / 30.0)
        }
        XCTAssertFalse(fired)
    }

    /// One long swing through the threshold is a single jolt, however many samples it spans —
    /// without this, a slow tip-over reads as a whole shake.
    func testSustainedHighReadingIsOneJolt() {
        var r = ShakeRecognizer()
        XCTAssertTrue(run(&r, seconds: 5) { _ in 3.0 }.isEmpty)
    }
}
