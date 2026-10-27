// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwarSaathiPrototype",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "SwarSaathiCore", targets: ["SwarSaathiCore"])],
    targets: [
        .target(name: "SwarSaathiCore", path: "Sources/SwarSaathi",
                exclude: ["SwarSaathiApp.swift", "PitchEngine.swift", "ScaleViewModel.swift",
                          "ScaleDiscoveryView.swift", "PracticeViewModel.swift", "PracticeView.swift",
                          "PitchGraphView.swift", "SummaryView.swift", "Theme.swift", "ReferenceAudio.swift"],
                sources: ["MusicTheory.swift", "PitchDetector.swift", "Calibration.swift", "PracticeTimeline.swift", "AudioPipeline.swift", "AudioProcessingRun.swift", "CalibrationCapture.swift"]),
        .testTarget(name: "SwarSaathiCoreTests", dependencies: ["SwarSaathiCore"], path: "Tests/SwarSaathiCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
