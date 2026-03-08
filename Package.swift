// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AXplore",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.11.0"),
    ],
    targets: [
        // Shared library: all AX reading, writing, analysis
        .target(
            name: "AXploreCore",
            dependencies: [],
            path: "Sources/AXploreCore"
        ),

        // CLI tool: axplore
        .executableTarget(
            name: "axplore",
            dependencies: [
                "AXploreCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/axplore"
        ),

        // MCP server: axmcp
        .executableTarget(
            name: "axmcp",
            dependencies: [
                "AXploreCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/axmcp"
        ),
    ]
)
