// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EagleReplica",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EagleReplica", targets: ["EagleReplica"])
    ],
    targets: [
        .executableTarget(
            name: "EagleReplica",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "EagleReplicaTests",
            dependencies: ["EagleReplica"]
        )
    ]
)
