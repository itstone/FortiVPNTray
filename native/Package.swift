// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FortiVPNTray",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FortiVPNCore", targets: ["FortiVPNCore"]),
        .executable(name: "FortiVPNTray", targets: ["FortiVPNTray"])
    ],
    targets: [
        .target(name: "FortiVPNCore"),
        .executableTarget(name: "FortiVPNTray", dependencies: ["FortiVPNCore"]),
        .testTarget(name: "FortiVPNCoreTests", dependencies: ["FortiVPNCore"])
    ]
)
