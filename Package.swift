// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CosmoAI",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "CosmoRealtime", targets: ["CosmoRealtime"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-openapi-runtime",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/apple/swift-openapi-urlsession",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/livekit/client-sdk-swift.git",
            // Floor 2.15.2: 2.15.1's #1044 wraps the SDK's ObjC auto-async
            // bridging in explicit checked continuations — the crash shape of
            // the macOS 26.1 first-mic-publish SIGSEGV (upstream
            // #1016). Earlier 2.x can resume a continuation against a freed
            // publication there.
            from: "2.15.2"
        ),
    ],
    targets: [
        // Generated models + client for the published developer API.
        // Implementation detail — consumers import ``CosmoRealtime`` only.
        //
        // ``Generated/`` is committed rather than produced by the OpenAPI
        // generator's build plugin, so this package needs no plugin approval
        // in Xcode and brings no code-generation dependencies with it.
        .target(
            name: "CosmoRealtimeAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            // Generator inputs, not build inputs — nothing reads them at
            // compile time now that the output is committed.
            exclude: [
                "openapi.json",
                "openapi-generator-config.yaml",
            ]
        ),
        .target(
            name: "CosmoRealtime",
            dependencies: [
                "CosmoRealtimeAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "CosmoRealtimeTests",
            dependencies: [
                "CosmoRealtime",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ]
        ),
        // E2E tests that run against a real ``livekit-server`` in dev
        // mode. Skipped unless ``LIVEKIT_TESTING_URL`` is set in the
        // environment. To run locally:
        //
        //   livekit-server --dev   (any local LiveKit server in dev mode)
        //   LIVEKIT_TESTING_URL=ws://localhost:7880 \
        //     LIVEKIT_TESTING_API_KEY=devkey \
        //     LIVEKIT_TESTING_API_SECRET=devsecretdevsecretdevsecretdevse \
        //     swift test
        .testTarget(
            name: "CosmoRealtimeE2ETests",
            dependencies: [
                "CosmoRealtime",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ]
        ),
    ]
)
