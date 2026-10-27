// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SwarSaathiDSPBaseline", targets: [
    .target(name: "SwarSaathiCore"),
    .testTarget(name: "SwarSaathiCoreTests", dependencies: ["SwarSaathiCore"])
], swiftLanguageVersions: [.v5])
