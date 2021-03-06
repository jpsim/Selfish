// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "Selfish",
    products: [
        .executable(name: "selfish", targets: ["selfish"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/SourceKitten.git", from: "0.23.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "2.0.0")
    ],
    targets: [
        .target(name: "selfish", dependencies: ["SourceKittenFramework", "Yams"])
    ]
)
