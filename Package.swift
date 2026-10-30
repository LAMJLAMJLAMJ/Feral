// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Feral",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FeralCore", targets: ["FeralCore"]),
        .library(name: "FeralScene", targets: ["FeralScene"]),
        .library(name: "FeralIO", targets: ["FeralIO"]),
        .library(name: "FeralOffline", targets: ["FeralOffline"]),
        .executable(name: "feral-engine", targets: ["feral-engine"]),
        .executable(name: "feral-cli", targets: ["feral-cli"]),
    ],
    targets: [
        // The real-time render core (C++20): delay lines, ramps, glides and crossfades, output
        // processing, and the Delay, VBAP and DBAP geometry. No Apple APIs, so it builds and tests on
        // Linux. Swift reaches it through the plain C API in include/feral_core.h.
        .target(name: "FeralCore"),
        // The Core Audio IOProc, in C++ so no Swift ever runs on the audio thread. macOS only; empty elsewhere.
        .target(name: "FeralCoreAudio", dependencies: ["FeralCore"]),
        // Engine settings, the fixed routing, and the spatial layout (speakers, groups, sources) that
        // SpatialRenderer turns into render states. The show file, snapshots and cues join it in milestone 3.
        .target(name: "FeralScene", dependencies: ["FeralCore"]),
        // Core Audio device list, opening one device and keeping it open. macOS only; empty elsewhere.
        .target(name: "FeralIO", dependencies: ["FeralCore", "FeralCoreAudio", "FeralScene"]),
        // The engine process, run by launchd (see launchd/ and scripts/install-engine.sh).
        .executableTarget(name: "feral-engine", dependencies: ["FeralCore", "FeralScene", "FeralIO"]),
        // Offline rendering through the same core, WAV files, and the known-answer checks.
        .target(name: "FeralOffline", dependencies: ["FeralCore", "FeralScene"]),
        // Offline checks and renders: feral-cli check, taps, impulse, render.
        .executableTarget(name: "feral-cli", dependencies: ["FeralOffline", "FeralScene"]),
        .testTarget(name: "FeralCoreTests", dependencies: ["FeralCore", "FeralScene"]),
        .testTarget(name: "FeralSceneTests", dependencies: ["FeralScene"]),
        .testTarget(name: "FeralOfflineTests", dependencies: ["FeralOffline", "FeralScene"]),
        .testTarget(name: "FeralIOTests", dependencies: ["FeralCore", "FeralCoreAudio", "FeralIO", "FeralScene"]),
    ],
    cxxLanguageStandard: .cxx20
)
