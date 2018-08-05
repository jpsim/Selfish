// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "Selfish",
    products: [
        .executable(name: "selfish", targets: ["selfish"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/SourceKitten.git", from: "0.21.1")
    ],
    targets: [
        .target(name: "selfish", dependencies: ["SourceKittenFramework"])
    ]
)
