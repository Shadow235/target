// swift-tools-version:5.9
import PackageDescription

// Čisté výpočetní jádro (bez UIKit/AVFoundation), aby šlo testovat
// i na Linuxu / v Dockeru: `swift test`.
let package = Package(
    name: "HitCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "HitCore", targets: ["HitCore"])
    ],
    targets: [
        .target(name: "HitCore"),
        .testTarget(name: "HitCoreTests", dependencies: ["HitCore"])
    ]
)
