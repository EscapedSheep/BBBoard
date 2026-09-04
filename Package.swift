// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BBBoard",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.5.0")
    ],
    targets: [
        .target(
            name: "RuleEngine"
        ),
        .target(
            name: "AIParser",
            dependencies: ["RuleEngine"]
        ),
        .target(
            name: "TaskStore",
            dependencies: [
                "RuleEngine",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "BoardApp",
            dependencies: [
                "RuleEngine",
                "TaskStore",
                "AIParser"
            ]
        ),
        .testTarget(
            name: "RuleEngineTests",
            dependencies: ["RuleEngine"]
        ),
        .testTarget(
            name: "TaskStoreTests",
            dependencies: ["TaskStore", "RuleEngine"]
        ),
        .testTarget(
            name: "AIParserTests",
            dependencies: ["AIParser", "RuleEngine"]
        )
    ]
)
