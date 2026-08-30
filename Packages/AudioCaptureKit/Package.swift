// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudioCaptureKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AudioCaptureKit", targets: ["AudioCaptureKit"])
    ],
    targets: [
        .target(name: "AudioCaptureKit"),
        .testTarget(name: "AudioCaptureKitTests", dependencies: ["AudioCaptureKit"])
    ]
)
