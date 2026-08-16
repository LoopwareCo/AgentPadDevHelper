// swift-tools-version:5.9
// AgentPadDevHelper — the standalone SDK an app under development embeds so AgentPad
// (or any MCP client) can drive its UI in-process. ONE package, ONE product, ONE
// module: third-party developers add this package and `import AgentPadDevHelper`.
// Deliberately has no dependency on AgentPadKit.
import PackageDescription

let package = Package(
    name: "AgentPadDevHelper",
    // The verified API floor is macOS 10.15 / iOS 15 (`withoutEscapingSlashes`,
    // `UIWindowScene.keyWindow`); macOS 12 gives margin against Xcode's own supported-deployment
    // floor. Kept deliberately LOW so adding the package never forces a deploy-target bump.
    platforms: [.macOS("12.0"), .iOS("15.0")],
    products: [
        .library(name: "AgentPadDevHelper", targets: ["AgentPadDevHelper"]),
    ],
    targets: [
        .target(name: "AgentPadDevHelper"),
        // A headless demo "app under development" that declares an AgentPad card, streams a value,
        // and applies control writes — so the DevKit round-trip is runnable via `swift run`.
        .executableTarget(name: "AgentPadDevSample", dependencies: ["AgentPadDevHelper"]),
    ]
)
