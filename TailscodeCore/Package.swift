// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TailscodeCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TailscodeCore", targets: ["TailscodeCore"])
    ],
    dependencies: [
        .package(path: "../../../swift/CodingAgentKit")
    ],
    targets: [
        .target(
            name: "TailscodeCore",
            dependencies: [
                .product(name: "CodingAgentKit", package: "CodingAgentKit"),
                .product(name: "CodingAgentKitApple", package: "CodingAgentKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TailscodeCoreTests",
            dependencies: ["TailscodeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
