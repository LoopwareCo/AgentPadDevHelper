/// The published package's coordinates — the ONE place AgentPad learns them from.
/// `Server.devHelperIntegrationInstructions` and the `install_dev_helper` tool interpolate these,
/// and `DevHelperSnippetTests` + `scripts/publish-devhelper.sh` guard them, so install
/// instructions can never drift from the published artifact again (published 1.0.0 was two
/// releases stale and nothing noticed).
public enum DevHelperPackage {
    /// The public repo the subtree split publishes to (`scripts/publish-devhelper.sh`).
    public static let repositoryURL = "https://github.com/LoopwareCo/AgentPadDevHelper"

    /// The version to hand out as `from:`. SwiftPM resolves UP from here, so being behind the
    /// newest published tag is harmless — being AHEAD of it is a hard resolve failure. That's why
    /// this is a checked constant and never derived from the app's own CFBundleVersion (dev builds
    /// bump constantly and would promise tags that were never published). `publish-devhelper.sh`
    /// refuses to publish a tag older than this.
    public static let minimumVersion = "1.0.0"
}
