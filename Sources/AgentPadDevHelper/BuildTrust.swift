import Foundation
#if os(macOS)
import Security
#endif

/// Is this process a build a DEVELOPER is running, or one that has been shipped to people?
///
/// `AgentPadDevHelper.start()` opens a channel that lets another process read this app's view
/// tree and activate its controls. That is exactly what you want on your own machine and never
/// what you want in an app real users are running, so the SDK decides for itself rather than
/// trusting the host app to remember. Two independent layers:
///
///  1. **Compile time.** `start()` is `#if DEBUG`, and SwiftPM builds a dependency with the same
///     configuration as the app — so archiving a Release build leaves literally no code to call.
///  2. **Runtime — this file.** The gap in layer 1 is a build that is *configured* Debug but
///     *distributed* anyway (the classic being a Debug-config archive pushed to TestFlight). So
///     before dialling out we look for positive evidence that this binary has been through a
///     distribution channel, and refuse if we find any.
///
/// Deliberately asymmetric: every check below is evidence of DISTRIBUTION, so an ordinary local
/// build — unsigned, ad-hoc signed, or signed with a development profile — is never disabled by
/// a false positive, and there's no flag for a developer to have to discover.
///
/// A note on what is NOT used here: the `com.apple.security.get-task-allow` *entitlement* looks
/// like the obvious "is this debuggable" signal, and on macOS it is not trustworthy for this —
/// locally signed builds vary, and this project's own release build carries it while its dev
/// build carries no entitlements at all. The provisioning PROFILE's copy of that key (checked
/// below) is a different, reliable thing: a profile is only embedded when one was used to sign.
public enum BuildTrust {

    /// What we concluded, and — when we refuse — a sentence the developer can act on.
    public enum Verdict: Equatable {
        case development
        case shipped(reason: String)

        public var isDevelopment: Bool { self == .development }
    }

    /// What we found out about this process. Split from the policy so the policy can be tested
    /// without building and signing a fixture app for each distribution channel.
    public struct Evidence: Equatable {
        /// An App Store receipt sits in the bundle (`_MASReceipt/receipt`, `StoreKit/receipt`).
        public var appStoreReceipt = false
        /// A *sandbox* receipt — TestFlight, or a StoreKit-sandbox install.
        public var testFlightReceipt = false
        /// macOS: the signature's leaf certificate is a "Developer ID Application" one, i.e. this
        /// was signed for distribution outside the App Store.
        public var developerIDSigned = false
        /// nil = no embedded provisioning profile (a plain local build); true = the profile grants
        /// `get-task-allow`, so it's a development profile; false = a distribution profile
        /// (App Store / ad-hoc / enterprise).
        public var profileAllowsDebugging: Bool?

        public init(appStoreReceipt: Bool = false, testFlightReceipt: Bool = false,
                    developerIDSigned: Bool = false, profileAllowsDebugging: Bool? = nil) {
            self.appStoreReceipt = appStoreReceipt
            self.testFlightReceipt = testFlightReceipt
            self.developerIDSigned = developerIDSigned
            self.profileAllowsDebugging = profileAllowsDebugging
        }
    }

    /// The policy. Ordered most-specific-first so the reason names the actual channel.
    public static func verdict(for evidence: Evidence) -> Verdict {
        if evidence.testFlightReceipt {
            return .shipped(reason: "this build carries a TestFlight receipt")
        }
        if evidence.appStoreReceipt {
            return .shipped(reason: "this build carries an App Store receipt")
        }
        if evidence.developerIDSigned {
            return .shipped(reason: "this build is signed with a Developer ID certificate")
        }
        if evidence.profileAllowsDebugging == false {
            return .shipped(reason: "this build is signed with a distribution provisioning profile")
        }
        return .development
    }

    /// The verdict for THIS process.
    public static var current: Verdict { verdict(for: gather()) }

    /// Inspect the running bundle. Cheap (a few file-exists checks and one signing-info read) and
    /// only ever called once, from `start()`.
    public static func gather() -> Evidence {
        var evidence = Evidence()
        let bundle = Bundle.main.bundleURL
        let fm = FileManager.default

        // Receipts. Built by hand rather than via `Bundle.appStoreReceiptURL`, which is deprecated
        // for Swift as of macOS 15 / iOS 18 in favour of StoreKit 2's async `AppTransaction` — no
        // use to a synchronous safety gate that must not touch the network.
        for directory in ["Contents/_MASReceipt", "StoreKit"] {
            let dir = bundle.appendingPathComponent(directory, isDirectory: true)
            if fm.fileExists(atPath: dir.appendingPathComponent("receipt").path) {
                evidence.appStoreReceipt = true
            }
            if fm.fileExists(atPath: dir.appendingPathComponent("sandboxReceipt").path) {
                evidence.testFlightReceipt = true
            }
        }

        // Provisioning profile, when one was embedded at signing time.
        for name in ["embedded.mobileprovision", "Contents/embedded.provisionprofile"] {
            let url = bundle.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            evidence.profileAllowsDebugging = profileGrantsGetTaskAllow(data)
            break
        }

        #if os(macOS)
        evidence.developerIDSigned = isDeveloperIDSigned()
        #endif
        return evidence
    }

    /// Does a provisioning profile grant `get-task-allow` (i.e. is it a DEVELOPMENT profile)?
    ///
    /// The profile is a CMS envelope wrapping an XML plist. Rather than decode the signature just
    /// to read one flag, scan for the key and take the first boolean element after it — the
    /// long-standing way to read a profile, and this is a hint used to REFUSE, never to grant
    /// anything, so a parse that finds nothing simply leaves the value nil.
    static func profileGrantsGetTaskAllow(_ data: Data) -> Bool? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        guard let key = text.range(of: "<key>get-task-allow</key>") else { return nil }
        let rest = text[key.upperBound...].prefix(200)
        guard let trueMark = rest.range(of: "<true/>") else {
            return rest.range(of: "<false/>") != nil ? false : nil
        }
        // Both markers can appear inside the window (adjacent keys) — the nearer one wins.
        if let falseMark = rest.range(of: "<false/>"), falseMark.lowerBound < trueMark.lowerBound {
            return false
        }
        return true
    }

    #if os(macOS)
    /// Is this binary signed with a "Developer ID Application" certificate — i.e. prepared for
    /// distribution outside the App Store? macOS only: on iOS there is no such channel, and
    /// `SecCode` isn't in the public SDK there.
    private static func isDeveloperIDSigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return false }
        let summary = SecCertificateCopySubjectSummary(leaf) as String?
        return summary?.hasPrefix("Developer ID Application") ?? false
    }
    #endif
}
