// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TailscodeMetal",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TailscodeMetal", targets: ["TailscodeMetal"]),
        .executable(name: "wall-render", targets: ["wall-render"]),
    ],
    dependencies: [
        .package(path: "../TailscodeCore")
    ],
    targets: [
        .target(
            name: "TailscodeMetal",
            dependencies: [.product(name: "TailscodeCore", package: "TailscodeCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "wall-render",
            dependencies: [
                "TailscodeMetal",
                .product(name: "TailscodeCore", package: "TailscodeCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TailscodeMetalTests",
            dependencies: [
                "TailscodeMetal",
                .product(name: "TailscodeCore", package: "TailscodeCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
