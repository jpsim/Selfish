// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "Selfish",
    products: [
        .executable(name: "selfish", targets: ["selfish"])
    ],
    dependencies: [
        .package(url: "https://github.com/1024jp/GzipSwift.git", from: "4.0.0"),
        .package(url: "https://github.com/jpsim/SourceKitten.git", from: "0.18.1"),
        .package(url: "https://github.com/onmyway133/SwiftHash.git", from: "2.0.1")
    ],
    targets: [
        .target(name: "selfish", dependencies: [
          "Gzip",
          "SourceKittenFramework",
          "SwiftHash"
        ])
    ]
)
