// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TailscodeLinux",
    products: [
        .executable(name: "tailscode", targets: ["TailscodeLinux"])
    ],
    dependencies: [
        .package(path: "../../../swift/CodingAgentKit"),
        .package(path: "../TailscodeCore"),
    ],
    targets: [
        .systemLibrary(
            name: "CAdw",
            pkgConfig: "libadwaita-1",
            providers: [.apt(["libadwaita-1-dev"]), .yum(["libadwaita-devel"])]
        ),
        .target(name: "CGtkShim", dependencies: ["CAdw"]),
        .executableTarget(
            name: "TailscodeLinux",
            dependencies: [
                "CAdw",
                "CGtkShim",
                .product(name: "CodingAgentKit", package: "CodingAgentKit"),
                .product(name: "CodingAgentKitApple", package: "CodingAgentKit"),
                .product(name: "TailscodeCore", package: "TailscodeCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
