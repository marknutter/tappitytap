// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "tappitytap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tappitytap-helper", targets: ["TappityTapHelper"]),
        .executable(name: "tappitytap",        targets: ["TappityTapApp"]),
    ],
    targets: [
        .target(name: "TappityTapShared"),
        .executableTarget(
            name: "TappityTapHelper",
            dependencies: ["TappityTapShared"]
        ),
        .executableTarget(
            name: "TappityTapApp",
            dependencies: ["TappityTapShared"]
        ),
    ]
)
