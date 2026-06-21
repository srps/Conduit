// swift-tools-version: 6.2
import PackageDescription

let nioProducts: [Target.Dependency] = [
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOPosix", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
    .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
]

let package = Package(
    name: "Conduit",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        // ProxyKernel is intentionally not a published library product: it has no
        // `public` API surface and is consumed only within this package. It will be
        // promoted to a library product if/when a stable external API is offered.
        .executable(name: "Conduit", targets: ["Conduit"]),
        .executable(name: "ConduitDaemon", targets: ["ConduitDaemon"]),
        .executable(name: "ConduitHelper", targets: ["ConduitHelper"]),
        .executable(name: "pm-proxy", targets: ["pm-proxy"]),
        .executable(name: "pm-dns", targets: ["pm-dns"]),
        .executable(name: "pm-tunnel", targets: ["pm-tunnel"]),
        .executable(name: "pm-sim", targets: ["pm-sim"]),
        .executable(name: "pmctl", targets: ["pmctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
    ],
    targets: [
        .target(
            name: "ConduitShared",
            path: "Sources/ConduitShared"
        ),
        // `ProxyKernel` is the portable, Apple-framework-free core; per-pillar
        // code lives in `ProxyAuth` / `ProxyPAC` / `PlatformMac`, and
        // cross-target protocols in `Sources/ProxyKernel/Abstractions/`. The
        // dependency graph is documented in `docs/design-module-split.md`.
        .target(
            name: "ProxyKernel",
            dependencies: nioProducts,
            path: "Sources/ProxyKernel",
            resources: [.process("Resources")]
        ),
        .target(
            name: "ProxyControlBridge",
            dependencies: ["ProxyKernel", "ConduitShared"],
            path: "Sources/ProxyControlBridge"
        ),
        .target(
            name: "ProxyAuth",
            dependencies: ["ProxyKernel"],
            path: "Sources/ProxyAuth"
        ),
        .target(
            name: "ProxyPAC",
            dependencies: ["ProxyKernel"],
            path: "Sources/ProxyPAC"
        ),
        .target(
            name: "PlatformMac",
            dependencies: ["ProxyKernel", "ConduitShared"],
            path: "Sources/PlatformMac"
        ),
        .executableTarget(
            name: "Conduit",
            dependencies: ["ProxyKernel", "ProxyAuth", "ProxyPAC", "PlatformMac"],
            path: "Sources/Conduit"
        ),
        .executableTarget(
            name: "pm-dns",
            dependencies: ["ProxyKernel"],
            path: "Sources/pm-dns"
        ),
        .executableTarget(
            name: "pm-proxy",
            dependencies: ["ProxyKernel", "ProxyControlBridge", "ProxyAuth", "ProxyPAC", "ConduitShared"],
            path: "Sources/pm-proxy"
        ),
        .executableTarget(
            name: "ConduitDaemon",
            dependencies: ["ProxyKernel", "ProxyControlBridge", "ProxyAuth", "ProxyPAC", "PlatformMac", "ConduitShared", .product(name: "NIOConcurrencyHelpers", package: "swift-nio")],
            path: "Sources/ConduitDaemon"
        ),
        .executableTarget(
            name: "pm-sim",
            dependencies: ["ProxyKernel", "ProxyAuth"] + nioProducts,
            path: "Sources/pm-sim"
        ),
        .executableTarget(
            name: "pm-tunnel",
            dependencies: ["ProxyKernel", "ProxyAuth"],
            path: "Sources/pm-tunnel"
        ),
        .executableTarget(
            name: "pmctl",
            dependencies: ["ConduitShared"],
            path: "Sources/pmctl"
        ),
        .executableTarget(
            name: "pm-vpn-check",
            dependencies: [
                "ProxyKernel",
                "PlatformMac",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Sources/pm-vpn-check"
        ),
        .executableTarget(
            name: "pm-auth-check",
            dependencies: ["ProxyKernel"],
            path: "Sources/pm-auth-check"
        ),
        .executableTarget(
            name: "pm-tls-check",
            dependencies: ["PlatformMac"],
            path: "Sources/pm-tls-check"
        ),
        .executableTarget(
            name: "ConduitHelper",
            dependencies: ["ConduitShared", "ProxyKernel"],
            path: "Sources/ConduitHelper"
        ),
        .testTarget(
            name: "ConduitTests",
            dependencies: [
                "Conduit",
                "ProxyKernel",
                "ProxyControlBridge",
                "ProxyAuth",
                "ProxyPAC",
                "PlatformMac",
                "ConduitShared",
                "ConduitDaemon",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Tests/ConduitTests"
        ),
    ]
)
