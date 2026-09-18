/// Which credential belongs in which parameter.
///
/// ``cosmo_…`` values are self-identifying, so an API key handed to `token:`
/// is a category error worth naming: the backend honors any ``cosmo_…``
/// bearer, so a key in that slot works right up until the app carrying it
/// reaches someone else. Traps with ``fatalError`` rather than throwing —
/// it is a programmer error caught on first run, and throwing would force
/// `try` onto every existing construction.
enum CredentialPlacement {

    /// An API key wearing a token's clothes — the backend would honor it as
    /// a bearer, which is exactly how a pasted key ends up shipped.
    /// Acts-as-user tokens (`cosmo_pat_…`) are a real bearer credential.
    static func isAPIKeyShaped(_ token: String) -> Bool {
        token.hasPrefix("cosmo_") && !token.hasPrefix("cosmo_pat_")
    }

    static let apiKeyInTokenSlotMessage =
        "This is a workspace API key (cosmo_…), not a minted end-user token. "
        + "Pass it as apiKey: — or mint a token for this user with "
        + "mintToken(_:ttlSeconds:) on your server and pass that. See "
        + "https://platform.askcosmo.ai/docs/production/end-user-credentials"
}
