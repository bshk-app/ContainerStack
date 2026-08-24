import Foundation

/// The update feed a bundle is allowed to trust.
///
/// Sparkle reads both values out of `Info.plist` and refuses to run without
/// them, so the decision of whether an updater may start at all is made here,
/// off the main actor and without linking Sparkle.
public struct UpdateFeed: Equatable, Sendable {
    /// What `stage-containerstack-app.sh` substitutes at staging time. A bundle
    /// still carrying it has no key, and a key-less Sparkle trusts any feed.
    public static let unsubstitutedKeyPlaceholder = "__SPARKLE_PUBLIC_ED_KEY__"

    public let url: URL
    public let publicKey: String

    public init(url: URL, publicKey: String) {
        self.url = url
        self.publicKey = publicKey
    }

    /// The feed for a bundle, or nil when this build must not check for updates.
    ///
    /// A plain `swift build` binary has no Info.plist at all and an unsigned
    /// stage carries the placeholder; both are normal during development, and
    /// neither may reach Sparkle - it treats a missing feed as a fatal
    /// configuration error rather than a reason to stay quiet.
    ///
    /// HTTPS is required because the feed names the download and its expected
    /// signature: over plain HTTP the enclosure URL is attacker-controlled, and
    /// Sparkle would be verifying whatever the attacker also chose to sign.
    public static func resolve(feedURL: String?, publicKey: String?) -> UpdateFeed? {
        guard
            let feedURL = feedURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            let publicKey = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            !publicKey.isEmpty,
            publicKey != Self.unsubstitutedKeyPlaceholder,
            let url = URL(string: feedURL),
            url.scheme == "https",
            url.host?.isEmpty == false
        else { return nil }

        return UpdateFeed(url: url, publicKey: publicKey)
    }
}
