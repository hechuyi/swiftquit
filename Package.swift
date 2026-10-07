// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftQuit",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SwiftQuit", targets: ["SwiftQuit"])],
    targets: [.executableTarget(name: "SwiftQuit", path: "Sources/SwiftQuit")],
    swiftLanguageVersions: [.v5]
)
