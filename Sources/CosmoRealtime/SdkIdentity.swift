/// The SwiftPM package name, sent as the SDK identity on ``session-config``
/// and the `X-Cosmo-SDK` request header.
public let sdkName = "cosmo-swift-sdk"

/// The package version, sent as the SDK identity on ``session-config`` and
/// the `X-Cosmo-SDK` request header.
public let sdkVersion = "0.8.0"

/// The `X-Cosmo-SDK` header value carried on every Cosmo REST call.
let sdkIdentityHeaderValue = "\(sdkName)/\(sdkVersion)"
