import Testing

@testable import ContainerStackCore

@Suite("An updater only starts for a bundle that can actually be updated")
struct UpdateFeedTests {
    /// Shaped like an Ed25519 key and deliberately not one: the rule under test
    /// is "anything but absent, empty or the staging placeholder", so pasting the
    /// production key here would only invite someone to trust this copy of it.
    private static let key = "dGVzdC1vbmx5LXB1YmxpYy1rZXktbm90LXJlYWw="
    private static let feed = "https://bshk-app.github.io/ContainerStack/appcast/stable.xml"

    @Test("a published bundle resolves its feed")
    func resolvesPublishedBundle() {
        let resolved = UpdateFeed.resolve(feedURL: Self.feed, publicKey: Self.key)
        #expect(resolved?.url.absoluteString == Self.feed)
        #expect(resolved?.publicKey == Self.key)
    }

    @Test("a development build has no Info.plist keys at all")
    func rejectsMissingKeys() {
        #expect(UpdateFeed.resolve(feedURL: nil, publicKey: nil) == nil)
        #expect(UpdateFeed.resolve(feedURL: Self.feed, publicKey: nil) == nil)
        #expect(UpdateFeed.resolve(feedURL: nil, publicKey: Self.key) == nil)
    }

    /// An empty or unsubstituted key is the dangerous case: Sparkle would accept
    /// any appcast, so a build in that state must not check for updates.
    @Test("an unsubstituted or empty key is not a key")
    func rejectsPlaceholderKey() {
        #expect(
            UpdateFeed.resolve(
                feedURL: Self.feed,
                publicKey: UpdateFeed.unsubstitutedKeyPlaceholder
            ) == nil
        )
        #expect(UpdateFeed.resolve(feedURL: Self.feed, publicKey: "") == nil)
        #expect(UpdateFeed.resolve(feedURL: Self.feed, publicKey: "   ") == nil)
    }

    /// The feed names the download and the signature it must carry, so plain HTTP
    /// hands an attacker both halves of the check.
    @Test("the feed has to be fetched over HTTPS")
    func rejectsInsecureFeed() {
        #expect(
            UpdateFeed.resolve(
                feedURL: "http://bshk-app.github.io/ContainerStack/appcast/stable.xml",
                publicKey: Self.key
            ) == nil
        )
        #expect(UpdateFeed.resolve(feedURL: "https:///appcast.xml", publicKey: Self.key) == nil)
        #expect(UpdateFeed.resolve(feedURL: "not a url", publicKey: Self.key) == nil)
    }
}
