// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "potof-toolkit",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "potof-toolkit",
            path: "Sources/potof-toolkit",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
