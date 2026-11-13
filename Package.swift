// swift-tools-version:5.9
//
// HMMCore: platform-independent inference, betting, simulation and speech-parsing
// logic for the "Beat the Dishonest Casino" prototype. The iOS app (iOSApp/) links
// this package; the `hmmcheck` executable runs the full mathematical verification
// suite and the demo/simulation from the command line on a Mac.
import PackageDescription

let package = Package(
    name: "HMMCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HMMCore", targets: ["HMMCore"]),
        .library(name: "HMMVerification", targets: ["HMMVerification"]),
        .executable(name: "hmmcheck", targets: ["hmmcheck"]),
    ],
    targets: [
        .target(name: "HMMCore"),
        // Verification checks live in a normal library so they can run both from
        // `swift run hmmcheck` (works with Command Line Tools only) and from XCTest
        // inside Xcode.
        .target(name: "HMMVerification", dependencies: ["HMMCore"]),
        .executableTarget(name: "hmmcheck", dependencies: ["HMMCore", "HMMVerification"]),
        .testTarget(name: "HMMCoreTests", dependencies: ["HMMCore", "HMMVerification"]),
    ]
)
