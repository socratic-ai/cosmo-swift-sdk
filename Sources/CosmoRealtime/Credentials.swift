import Foundation

public struct Credentials: Sendable, Equatable {
    public let apiKey: String
    public let apiURL: URL
    public let userId: String?
    public let userEmail: String?

    public init(
        apiKey: String,
        apiURL: URL,
        userId: String? = nil,
        userEmail: String? = nil
    ) {
        self.apiKey = apiKey
        self.apiURL = apiURL
        self.userId = userId
        self.userEmail = userEmail
    }
}

extension Credentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let masked = Self.maskKey(apiKey)
        return "Credentials(apiKey: \(masked), apiURL: \(apiURL.absoluteString))"
    }

    public var debugDescription: String { description }

    private static func maskKey(_ key: String) -> String {
        guard key.count > 8 else { return "••••" }
        let last4 = key.suffix(4)
        return "cosmo_••••\(last4)"
    }
}
