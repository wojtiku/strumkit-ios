// swift-tools-version:5.9
import PackageDescription

// Standalone SwiftPM package. Deliberately independent of StrumKit.xcodeproj and
// of `project.yml`: this is a *reference port* of somebody else's engine, not a
// change to StrumKit, and it must keep building and testing even while the main
// Xcode project is being edited.
//
// Accelerate is a system framework on Apple platforms; the package is macOS-only
// because vDSP (and therefore the Ooura/vDSP FFT) is what the port uses.
let package = Package(
    name: "WebTunaReference",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "WebTunaReference", targets: ["WebTunaReference"])
    ],
    targets: [
        .target(
            name: "WebTunaReference",
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .testTarget(
            name: "WebTunaReferenceTests",
            dependencies: ["WebTunaReference"]
        ),
    ]
)
