import XCTest
@testable import AgentPadDevHelper

#if os(macOS)

/// Whether an app reports an icon at all.
///
/// macOS has no "this app has no icon" answer — `NSApplication.applicationIconImage` hands back the
/// system's generic app artwork, and an SDK that forwards it is telling the server the placeholder
/// IS the app. AgentPad then lends a connected app's icon to the project it runs in, so that one
/// wrong "yes" paints a real project with the same grey square every iconless app produces. The rule
/// is the bundle's own metadata, and these are its cases.
final class AppIconReportingTests: XCTestCase {

    /// The rule with nothing on disk: nothing resolves.
    private func declares(_ info: [String: Any],
                          assets: Set<String> = [], resources: Set<String> = []) -> Bool {
        AppIdentity.declaresOwnIcon(info: info,
                                    asset: { assets.contains($0) }, resource: { resources.contains($0) })
    }

    func testAnAppThatDeclaresNoIconHasNone() {
        XCTAssertFalse(declares([:]))
        XCTAssertFalse(declares(["CFBundleName": "HelloWorldMac"]))
    }

    func testAnAssetCatalogIconCounts() {
        XCTAssertTrue(declares(["CFBundleIconName": "AppIcon"], assets: ["AppIcon"]))
    }

    func testAnIcnsFileCounts() {
        XCTAssertTrue(declares(["CFBundleIconFile": "MyApp"], resources: ["MyApp"]))
        XCTAssertTrue(declares(["CFBundleIconFiles": ["Small", "MyApp"]], resources: ["MyApp"]))
    }

    /// A key is a claim, not artwork: a bundle that names an icon it no longer ships still shows the
    /// system placeholder, so it must not be reported as having one.
    func testADeclaredIconThatIsNoLongerThereDoesNotCount() {
        XCTAssertFalse(declares(["CFBundleIconName": "AppIcon"]))
        XCTAssertFalse(declares(["CFBundleIconFile": "MyApp"]))
    }

    func testAnEmptyIconKeyIsNotAnIcon() {
        XCTAssertFalse(declares(["CFBundleIconName": "", "CFBundleIconFile": ""],
                                assets: [""], resources: [""]))
    }
}

#endif
