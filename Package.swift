// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "tiden-swift",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tiden-swift", targets: ["tiden-swift"]),
        .library(name: "TidenReporterCore", targets: ["TidenReporterCore"]),
        .library(name: "TidenXCResult", targets: ["TidenXCResult"])
    ],
    targets: [
        .target(name: "TidenReporterCore"),
        .target(name: "TidenXCResult", dependencies: ["TidenReporterCore"]),
        .executableTarget(name: "tiden-swift", dependencies: ["TidenReporterCore", "TidenXCResult"]),
        .testTarget(name: "TidenReporterTests", dependencies: ["TidenReporterCore", "TidenXCResult"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
