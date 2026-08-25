// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "COGOSLinuxCompile",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IMAPCore", targets: ["IMAPCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/Cocoanetics/SwiftMail", exact: "1.11.0")
    ],
    targets: [
        .target(
            name: "IMAPCore",
            dependencies: [
                .product(name: "SwiftMail", package: "SwiftMail")
            ]
        )
    ]
)
