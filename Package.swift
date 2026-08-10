// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "findtree",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "FindTreeCore", targets: ["FindTreeCore"]),
        .executable(name: "findtree", targets: ["findtree"]),
        .executable(name: "FindTreeApp", targets: ["FindTreeApp"])
    ],
    targets: [
        .target(name: "FindTreeCore"),
        .executableTarget(name: "findtree", dependencies: ["FindTreeCore"]),
        .executableTarget(name: "FindTreeApp", dependencies: ["FindTreeCore"]),
        .testTarget(name: "FindTreeCoreTests", dependencies: ["FindTreeCore"])
    ]
)
