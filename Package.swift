// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Beeper's iMessage automation: tapbacks, which have no public API, through a hidden copy of Messages.
        .package(url: "https://github.com/beeper/platform-imessage.git", exact: "0.26.0"),
    ],
    targets: [
        .executableTarget(
            name: "Perch",
            dependencies: [.product(name: "IMessage", package: "platform-imessage")],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "PerchTests", dependencies: ["Perch"], swiftSettings: [.defaultIsolation(MainActor.self)]),
    ]
)
