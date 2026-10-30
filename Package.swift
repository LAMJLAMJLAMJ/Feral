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
        .library(name: "FeralControl", targets: ["FeralControl"]),
        .executable(name: "feral-engine", targets: ["feral-engine"]),
        .executable(name: "feral-cli", targets: ["feral-cli"]),
        .executable(name: "Feral", targets: ["FeralApp"]),
    ],
    targets: [
        // The real-time render core (C++20): delay lines, ramps, glides and crossfades, output
        // processing, and the Delay, VBAP and DBAP geometry. No Apple APIs, so it builds and tests on
        // Linux. Swift reaches it through the plain C API in include/feral_core.h.
        .target(name: "FeralCore"),
        // The Core Audio IOProc, in C++ so no Swift ever runs on the audio thread. macOS only; empty elsewhere.
        .target(name: "FeralCoreAudio", dependencies: ["FeralCore"]),
        // Engine settings, the fixed routing, the show (sources, speakers, groups, snapshots, cues), its
        // .feralshow package and journal, the commands that change it, snapshot fades, and the
        // SpatialRenderer that turns the layout into render states.
        .target(name: "FeralScene", dependencies: ["FeralCore"]),
        // The control link between the engine and the app or feral-cli: JSON lines over TCP. The
        // messages build everywhere; the server and client use Network.framework (macOS).
        .target(name: "FeralControl", dependencies: ["FeralScene"]),
        // Core Audio device list, opening one device and keeping it open. macOS only; empty elsewhere.
        .target(name: "FeralIO", dependencies: ["FeralCore", "FeralCoreAudio", "FeralScene"]),
        // The engine process, run by launchd (see launchd/ and scripts/install-engine.sh).
        .executableTarget(name: "feral-engine", dependencies: ["FeralCore", "FeralScene", "FeralIO", "FeralControl"]),
        // Offline rendering through the same core, WAV files, and the known-answer checks.
        .target(name: "FeralOffline", dependencies: ["FeralCore", "FeralScene"]),
        // Offline checks and renders (check, taps, impulse, render), show files (show import, show info),
        // and the running engine from Terminal (status, go, recall, move, store, cue, save).
        .executableTarget(name: "feral-cli", dependencies: ["FeralOffline", "FeralScene", "FeralControl"]),
        // The Feral Mac app (SwiftUI): the plan view, sources, snapshots and cues, talking to the engine
        // over the control link. macOS only; a stub elsewhere. scripts/build-app.sh bundles it.
        .executableTarget(name: "FeralApp", dependencies: ["FeralScene", "FeralControl"]),
        .testTarget(name: "FeralCoreTests", dependencies: ["FeralCore", "FeralScene"]),
        .testTarget(name: "FeralSceneTests", dependencies: ["FeralScene"]),
        .testTarget(name: "FeralControlTests", dependencies: ["FeralControl", "FeralScene"]),
        .testTarget(name: "FeralOfflineTests", dependencies: ["FeralOffline", "FeralScene"]),
        .testTarget(name: "FeralIOTests", dependencies: ["FeralCore", "FeralCoreAudio", "FeralIO", "FeralScene"]),
    ],
    cxxLanguageStandard: .cxx20
)
