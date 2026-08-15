// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TranscriptionKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"])
    ],
    targets: [
        // Built by Scripts/setup.sh via Vendor/whisper.cpp/build-xcframework.sh before this
        // package is built. Local-path binary targets are resolved from disk at build time,
        // so the xcframework must already exist — see README "First-time setup".
        .binaryTarget(
            name: "whisper",
            path: "../../Vendor/whisper.cpp/build-apple/whisper.xcframework"
        ),
        .target(
            name: "TranscriptionKit",
            dependencies: ["whisper"]
        ),
        .testTarget(
            name: "TranscriptionKitTests",
            dependencies: ["TranscriptionKit"],
            resources: [.copy("Fixtures/jfk.wav")]
        )
    ]
)
