// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InputInjectionKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "InputInjectionKit", targets: ["InputInjectionKit"])
    ],
    targets: [
        .target(name: "InputInjectionKit"),
        .testTarget(name: "InputInjectionKitTests", dependencies: ["InputInjectionKit"])
    ]
)
