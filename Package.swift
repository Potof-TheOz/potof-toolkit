// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "potof-toolkit",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // SwiftTerm : émulateur de terminal xterm en Swift (MIT). Fournit
        // `LocalProcessTerminalView` (AppKit) qui possède le PTY + le process
        // enfant → l'app héberge elle-même les sessions `claude`.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    ],
    targets: [
        .executableTarget(
            name: "potof-toolkit",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/potof-toolkit",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
