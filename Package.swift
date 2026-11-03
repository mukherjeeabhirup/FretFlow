// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FretFlow",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FretFlow", targets: ["FretFlow"])],
    targets: [.executableTarget(name: "FretFlow", path: "Sources/FretFlow")]
)
