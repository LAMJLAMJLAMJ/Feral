// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Feral",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FeralCore", targets: ["FeralCore"]),
        .library(name: "FeralScene", targets: ["FeralScene"]),
        .library(name: "FeralIO", targets: ["FeralIO"]),
        .executable(name: "feral-engine", targets: ["feral-engine"]),
    ],
    targets: [
        // The real-time render core (C++20). No Apple APIs, so it builds and tests on Linux.
        // Swift reaches it through the plain C API in include/feral_core.h.
        .target(name: "FeralCore"),
        // The Core Audio IOProc, in C++ so no Swift ever runs on the audio thread. macOS only; empty elsewhere.
        .target(name: "FeralCoreAudio", dependencies: ["FeralCore"]),
        // Engine settings and the fixed routing that becomes the gain matrix. The scene model,
        // snapshots and cues join it in milestone 3.
        .target(name: "FeralScene", dependencies: ["FeralCore"]),
        // Core Audio device list, opening one device and keeping it open. macOS only; empty elsewhere.
        .target(name: "FeralIO", dependencies: ["FeralCore", "FeralCoreAudio", "FeralScene"]),
        // The engine process, run by launchd (see launchd/ and scripts/install-engine.sh).
        .executableTarget(name: "feral-engine", dependencies: ["FeralCore", "FeralScene", "FeralIO"]),
        .testTarget(name: "FeralCoreTests", dependencies: ["FeralCore", "FeralScene"]),
        .testTarget(name: "FeralSceneTests", dependencies: ["FeralScene"]),
        .testTarget(name: "FeralIOTests", dependencies: ["FeralCore", "FeralCoreAudio", "FeralIO", "FeralScene"]),
    ],
    cxxLanguageStandard: .cxx20
)
