// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Perch", swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "PerchTests", dependencies: ["Perch"], swiftSettings: [.defaultIsolation(MainActor.self)]),
    ]
)
