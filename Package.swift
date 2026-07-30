// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CosmoRealtime",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "CosmoRealtime", targets: ["CosmoRealtime"]),
        // The iOS on-device tool library any CosmoRealtime app can advertise +
        // run — the SDK analog of the macOS app's RealtimeMacTools (the platform
        // + Tools intent rides in the module name, like that target). Vision is
        // the first tool family. Kept separate from the OpenAPI-generated
        // transport target so Apple frameworks stay out of it and the dep is
        // opt-in.
        .library(name: "CosmoRealtimeiOSTools", targets: ["CosmoRealtimeiOSTools"]),
        // The opt-in ARKit face-tracking backend — a peer of the Vision toolbox,
        // not nested in it, so the heavy TrueDepth-only framework stays opt-in.
        // The pure FaceAnchorSnapshot/ARFaceGeometryProjector compile everywhere
        // (CI tests them); only the live source is #if os(iOS)-gated.
        .library(name: "CosmoRealtimeARKit", targets: ["CosmoRealtimeARKit"]),
        // On-device session notes: data model, file store, search, the
        // client-declared note tool pack, and the end-of-session recapper.
        // Depends only on CosmoRealtime (no Apple-app frameworks) so any
        // CosmoRealtime app can opt in.
        .library(name: "CosmoNotesKit", targets: ["CosmoNotesKit"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-openapi-generator",
            from: "1.6.0"
        ),
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
            // the macOS 26.1 first-mic-publish SIGSEGV (cosmo #6932, upstream
            // #1016). Earlier 2.x can resume a continuation against a freed
            // publication there.
            from: "2.15.2"
        ),
    ],
    targets: [
        // Generated models + client for the published developer API
        // (``../external-openapi.json``). Separate module because its
        // generated ``Components`` namespace shares schema names with the
        // legacy spec generated into ``CosmoRealtime`` below; the two
        // coexist until the legacy surface is retired. Implementation
        // detail — consumers import ``CosmoRealtime`` only.
        .target(
            name: "CosmoRealtimeAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
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
        .target(
            name: "CosmoRealtimeiOSTools",
            dependencies: ["CosmoRealtime"]
        ),
        .target(
            name: "CosmoRealtimeARKit",
            dependencies: ["CosmoRealtime"]
        ),
        .target(
            name: "CosmoNotesKit",
            dependencies: ["CosmoRealtime"]
        ),
        .testTarget(
            name: "CosmoRealtimeTests",
            dependencies: [
                "CosmoRealtime",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "CosmoRealtimeiOSToolsTests",
            dependencies: ["CosmoRealtimeiOSTools"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CosmoRealtimeARKitTests",
            dependencies: ["CosmoRealtimeARKit"]
        ),
        .testTarget(
            name: "CosmoNotesKitTests",
            dependencies: ["CosmoNotesKit"]
        ),
        // E2E tests that run against a real ``livekit-server`` in dev
        // mode. Skipped unless ``LIVEKIT_TESTING_URL`` is set in the
        // environment. To run locally:
        //
        //   cd backend/scripts && docker compose -f docker-compose.livekit.yml up -d
        //   cd sdks/cosmo-realtime/swift
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
