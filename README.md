# Feral

In-house spatial audio engine for immersive live sound, on macOS. The design is in the [v1 technical design](https://claude.ai/artifact/313W4TBPo6gruTH6rBM8qq) and the background in the [platforms research](https://claude.ai/artifact/DeXcLoQPN3MHfYYRwwTGy9).

This is **milestone 1, the engine skeleton**: a headless `feral-engine` process that opens one Core Audio device, plays up to 128 inputs to 128 outputs through a fixed gain matrix, changes that matrix without a click, and is restarted by launchd if it crashes. The renderers (Delay, VBAP, DBAP) come in milestone 2 and the Mac app in milestone 3.

## What's here

| Part | Contents |
| --- | --- |
| `Sources/FeralCore` | The real-time render core in C++20: render states, the gain matrix with per-buffer ramps, and the lock-free swap between the control and audio threads. No Apple APIs, so it builds and tests on Linux. Swift reaches it through the C API in `include/feral_core.h`. |
| `Sources/FeralCoreAudio` | The Core Audio IOProc, in C++ so no Swift runs on the audio thread. It maps the device's streams (mono or interleaved) to engine channels. macOS only. |
| `Sources/FeralScene` | Engine settings (`engine.json`) and the routing that becomes the gain matrix. The scene model, snapshots and cues join it in milestone 3. |
| `Sources/FeralIO` | Core Audio device list, opening one device, and keeping it open: if it disappears, changes sample rate or changes its channels, the engine keeps its state and reopens it every second until it is back. macOS only. |
| `Sources/feral-engine` | The engine process. |
| `launchd/local.feral.engine.plist` | The launchd agent: starts at login, restarts within about a second after a crash. |
| `scripts/` | `build-engine-app.sh` (bundle), `install-engine.sh` (install or update the agent), `engine.sh` (status, log, reload, restart, stop, crash test). |
| `Tests/` | Known-answer tests for the matrix and ramps, the state swap under concurrent publishing (run under the thread sanitizer on Linux CI), a timing check for a dense 128 by 128 matrix, and the IOProc on hand-made mono and interleaved buffer lists (macOS). |

### How a change reaches the audio

The control thread builds a new immutable render state (the matrix's non-zero gains per output) and publishes it by storing one atomic pointer. At the start of its next buffer the audio thread sees the new pointer, ramps every gain from the old value to the new one over that buffer, and records the state's sequence number. Anything older than that number can never be read again, so the housekeeping timer frees it. The audio thread never allocates, locks or logs. When the device stops, the next start fades in from silence over one buffer.

## Getting started on your Mac

You need Xcode 16 or later (Swift 5.9+), on macOS 14 or later.

```sh
git clone https://github.com/LAMJLAMJLAMJ/Feral.git
cd Feral
swift test -c release           # run all tests
swift run feral-engine devices  # list audio devices with their UIDs and channel counts
```

### Install the engine

```sh
./scripts/install-engine.sh "MADIface XT"   # the device's UID or part of its name
./scripts/engine.sh log                      # watch it start
```

This builds `FeralEngine.app` (the engine inside a minimal app bundle, so macOS can ask once for audio input access), copies it to `~/Library/Application Support/Feral/`, writes `engine.json` there on first install, and starts the launchd agent. The first start asks for microphone access for "Feral Engine": allow it, or every input is silent. Run the script again after pulling changes to update the engine; `engine.json` is kept.

`./scripts/engine.sh crash` makes the engine crash on purpose; `./scripts/engine.sh status` should show it running again with a new pid about a second later. `./scripts/engine.sh stop` stops it cleanly and launchd leaves it stopped until `start` or the next login. `./scripts/engine.sh uninstall` removes the agent.

### Settings: engine.json

`~/Library/Application Support/Feral/engine.json`. Every key is optional. After editing, `./scripts/engine.sh reload` applies it without stopping: a new routing ramps in over one buffer, and device changes reopen the device.

| Key | Default | Meaning |
| --- | --- | --- |
| `device` | none | The device's UID (best: from `feral-engine devices`) or part of its name |
| `sampleRate` | 48000 | Set on the device when the engine opens it |
| `bufferFrames` | 64 | Core Audio buffer size. 64 for shows; 128 or 256 is fine while programming |
| `inputs`, `outputs` | 128, 128 | Engine channels, up to 256 each |
| `firstInputChannel`, `firstOutputChannel` | 1, 1 | The device channel (from 1) that engine channel 1 uses; the rest follow in order |
| `routes` | passthrough | The fixed gain matrix: a list of `{ "inputs": "1-64", "outputs": "65-128", "gainDB": -3 }`. Equal-sized ranges pair up in order, one input to many outputs feeds them all, many inputs to one output sum. No routes means input n to output n |
| `refuseAggregateDevices` | true | Aggregate devices drift or resample between clocks, so the engine refuses them |

The engine refuses aggregate devices and needs 32-bit float streams (every pro interface we use presents them). The device must be clocked from the house clock or the network; the engine follows it and logs any sample rate change as a fault.

### Testing 128 outputs on an RME MADIface XT

At 48 kHz each MADI port carries 64 channels, so 128 outputs need two of the XT's MADI ports; `feral-engine devices` shows how many channels the driver presents, and `firstOutputChannel` picks where the engine's outputs start. To feed one test signal on input 1 to every output at -20 dB:

```json
{
  "device": "MADIface XT",
  "bufferFrames": 64,
  "inputs": 1,
  "outputs": 128,
  "routes": [ { "inputs": 1, "outputs": "1-128", "gainDB": -20 } ]
}
```

For a straight 128-channel passthrough, leave out `inputs`, `outputs` and `routes`. The log line at start says how many engine channels found a device channel, the buffer size the device accepted and the latency it reports; every 10 seconds the engine logs a warning if any buffer ran late (over 80 % of its time), Core Audio reported an overload, or a buffer was skipped, and every 5 minutes it logs a status line.

## Not yet

Milestone 1 does not have renderers, the show file and journal, OSC control, render worker threads (one audio thread handles 128 by 128 easily, see the timing test), show mode, or the backup engine. They follow the milestones in the design.
