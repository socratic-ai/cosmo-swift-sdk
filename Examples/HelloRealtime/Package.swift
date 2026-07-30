// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HelloRealtime",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        // ``name:`` aliases the path-based parent to ``CosmoRealtime`` —
        // without it SwiftPM falls back to the parent directory name
        // (``swift``), which then fails to resolve ``package: "CosmoRealtime"``
        // below. Once the SDK ships from its canonical published repo,
        // path-based consumers like this example keep working as long as
        // the alias matches the package's ``name:``.
        .package(name: "CosmoRealtime", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "HelloRealtime",
            dependencies: [
                .product(name: "CosmoRealtime", package: "CosmoRealtime"),
            ],
            path: "Sources/HelloRealtime"
        ),
        .executableTarget(
            name: "MCPExample",
            dependencies: [
                .product(name: "CosmoRealtime", package: "CosmoRealtime"),
            ],
            path: "Sources/MCPExample"
        ),
        .executableTarget(
            name: "HooksExample",
            dependencies: [
                .product(name: "CosmoRealtime", package: "CosmoRealtime"),
            ],
            path: "Sources/HooksExample"
        ),
        .executableTarget(
            name: "SkillsExample",
            dependencies: [
                .product(name: "CosmoRealtime", package: "CosmoRealtime"),
            ],
            path: "Sources/SkillsExample"
        ),
    ]
)
