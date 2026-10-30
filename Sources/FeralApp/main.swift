// Feral: the Mac app. It shows the engine's show (speakers, groups, sources, snapshots, cues) on a
// plan, moves sources with the mouse, stores and recalls snapshots and runs the cue list, all through
// the control link to feral-engine (on this Mac, or another one). The engine keeps playing if the app
// quits or crashes. Build the app bundle with scripts/build-app.sh, or try it with `swift run Feral`.
#if canImport(SwiftUI) && os(macOS)
FeralApp.main()
#else
print("The Feral app runs on macOS only.")
#endif
