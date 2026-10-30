# Feral

In-house spatial audio engine for immersive live sound, on macOS. The design is in the [v1 technical design](https://claude.ai/artifact/313W4TBPo6gruTH6rBM8qq) and the background in the [platforms research](https://claude.ai/artifact/DeXcLoQPN3MHfYYRwwTGy9).

This is **milestone 2, the renderers**, on top of milestone 1's engine skeleton: a headless `feral-engine` process that opens one Core Audio device and renders up to 128 sources to 128 speakers through Delay, VBAP and DBAP speaker groups, with per-speaker processing, and is restarted by launchd if it crashes. Sources, speakers and groups are set in `engine.json` for now; the show file and the Mac app come in milestone 3, and OSC control in milestone 4.

## What's here

| Part | Contents |
| --- | --- |
| `Sources/FeralCore` | The real-time render core in C++20: render states, per-source delay lines, gain ramps, delay glides and crossfades, per-output processing, and the lock-free swap between the control and audio threads. Also the renderers' geometry (`include/feral_geometry.h`): Delay, VBAP (2D pairs, 3D triangulation with virtual speakers, MDAP width) and DBAP, and EQ design. No Apple APIs, so it builds and tests on Linux. Swift reaches it through the C API in `include/feral_core.h`. |
| `Sources/FeralCoreAudio` | The Core Audio IOProc, in C++ so no Swift runs on the audio thread. It maps the device's streams (mono or interleaved) to engine channels. macOS only. |
| `Sources/FeralScene` | Engine settings (`engine.json`), the fixed routing, and the spatial layout (speakers, groups, sources) that `SpatialRenderer` turns into render states. The show file, snapshots and cues join it in milestone 3. |
| `Sources/FeralOffline`, `Sources/feral-cli` | Offline rendering through the same core, WAV files, and the known-answer checks. `feral-cli check`, `taps`, `impulse` and `render`. |
| `Sources/FeralIO` | Core Audio device list, opening one device, and keeping it open: if it disappears, changes sample rate or changes its channels, the engine keeps its state and reopens it every second until it is back. macOS only. |
| `Sources/feral-engine` | The engine process. |
| `launchd/local.feral.engine.plist` | The launchd agent: starts at login, restarts within about a second after a crash. |
| `scripts/` | `build-engine-app.sh` (bundle), `install-engine.sh` (install or update the agent), `engine.sh` (status, log, reload, restart, stop, crash test). |
| `examples/stage-test.json` | A 26-speaker test layout: a Delay group (front line, fills, delays), a VBAP overhead ring, two subs on the LFE send, and a test source orbiting the stage. |
| `Tests/` | The known-answer checks, delay taps, spatial settings and WAV files; from milestone 1, the matrix and ramps, the state swap under concurrent publishing (run under the thread sanitizer on Linux CI), a timing check for a dense 128 by 128 matrix, and the IOProc on hand-made mono and interleaved buffer lists (macOS). |

### How a change reaches the audio

The control thread builds a new immutable render state (every output's taps: an input at a gain, straight or through the input's delay line, plus the output's processing) and publishes it by storing one atomic pointer. At the start of its next buffer the audio thread sees the new pointer and matches the new taps to the ones playing:

- a gain moves to its new value over one buffer, or over 50 ms when the change is a group, send or renderer change (an `engine.json` reload);
- a tap that is gone fades out, and a new one fades in;
- a delay glides to its new value at no more than a 0.5 % pitch shift, or, if it jumps by more than 5 ms, crossfades from the old delay to the new one over 30 ms;
- an output's alignment delay moves the same way, EQ coefficients interpolate over one buffer, and trim, polarity and mute ramp over one buffer.

It then records the state's sequence number; anything older can never be read again, so the housekeeping timer frees it. The audio thread never allocates, locks or logs. When the device stops, the delay lines and filters are cleared and the next start fades in from silence over one buffer.

### The renderers

Every source feeds each group it sends to, and each group's renderer turns the source's position into a gain (and for Delay groups a delay) per speaker. Positions are in metres: x to stage right, y towards the audience, z up, origin at stage centre on the stage floor.

- **Delay** (the main one for live, TiMax and Soundscape style): every speaker plays the source with the delay and level it would have if the sound came from the source's position, plus a precedence offset, so the first arrival at every seat is from the stage. Delay = (distance - nearest speaker's distance) / c + precedence; level = 6 dB less per doubling of distance beyond the nearest speaker (`rolloff` 1). Delays are read with 4-point Lagrange interpolation.
- **VBAP** (overheads, domes, rings, lines): direction from the group's reference point; pairs in 2D, convex-hull triangles in 3D, with a virtual speaker closing an open dome underneath whose share is spread to its neighbours. `width` on a source spreads it (MDAP). Distance only changes level.
- **DBAP** (irregular layouts with no sweet spot): gain falls with distance from each speaker (`rolloffDB` per doubling), with `blur` so one speaker never takes everything.

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
| `testSignal` | `"off"` | `"pink"` or `"sine"` plays a generated signal in place of input 1, to check outputs with nothing plugged in |
| `testSignalDB`, `testSignalHz` | -20, 1000 | The test signal's RMS level in dB re full scale (a sine peaks 3 dB higher), and the sine's frequency |
| `speakers` | none | The speakers, below |
| `groups` | none | The speaker groups, below. With groups set, the engine renders `sources` to them, and `routes` only adds fixed feeds on top (no passthrough) |
| `sources` | none | The sources, below |
| `lfeOutputs` | none | The outputs a source's `lfeDB` send feeds, such as `"25-26"` |
| `airTemperatureC` | 20 | Sets the speed of sound for Delay groups |
| `delayGlidePercent`, `delayJumpMS`, `delayCrossfadeMS` | 0.5, 5, 30 | A moving delay glides at most this fast (as a pitch shift); a jump bigger than `delayJumpMS` crossfades instead, over `delayCrossfadeMS` |
| `groupCrossfadeMS` | 50 | How long a reload's group, send or renderer changes take |
| `testMotion` | none | Moves one source by itself: `{ "source": 1, "shape": "circle", "center": [0, 6, 1.6], "radius": 6, "seconds": 20 }`, or `"shape": "line"` with `"from"` and `"to"` |

A **speaker**: `{ "output": 3, "name": "Main L", "position": [-6, 0, 5], "delayMS": 0, "trimDB": 0, "invert": false, "mute": false, "eq": [ { "type": "highPass", "hz": 80 }, { "type": "peak", "hz": 2500, "q": 2, "gainDB": -3 } ], "limiterDB": -1, "limiterReleaseMS": 200 }`. Only `output` and `position` are needed. `delayMS`, EQ (up to 8 bands: `peak`, `lowShelf`, `highShelf`, `lowPass`, `highPass`, `notch`, `allPass`), trim, `invert` (polarity), the limiter (none unless `limiterDB` is set; it has no look-ahead, so no latency) and `mute` are the system layer, which cues will never touch.

A **group**: `{ "name": "Main", "renderer": "delay", "speakers": "1-16" }`, with `gainDB` and `weightsDB` (per output: `{ "5": -6 }`) for any renderer, then per renderer:

| Renderer | Keys (defaults) |
| --- | --- |
| `delay` | `precedenceMS` (10), `rolloff` (1: 6 dB per doubling), `referenceDistance` (the nearest speaker's distance, at least 1 m), `distanceOffset` (the nearest speaker's distance) |
| `vbap` | `reference` (the speakers' centre in plan, 1.2 m up), `dimensions` (2 when the speakers are all at about one elevation, else 3), `rolloff` (1), `referenceDistance` (the speakers' mean distance) |
| `dbap` | `blur` (0.5 m), `rolloffDB` (6) |

A speaker can be in one Delay group only (it can also be in VBAP and DBAP groups, whose feeds add up).

A **source**: `{ "input": 1, "name": "Vox", "position": [0, 2, 1.6], "gainDB": 0, "mute": false, "width": 0, "groups": { "Main": 0, "Overheads": -6 }, "lfeDB": -10 }`. `groups` can also be a list of names (each at 0 dB); left out, the source goes to every group at 0 dB. `width` is in degrees and only affects VBAP groups.

The engine refuses aggregate devices and needs 32-bit float streams (every pro interface we use presents them). The device must be clocked from the house clock or the network; the engine follows it and logs any sample rate change as a fault.

### Testing 128 outputs on an RME MADIface XT

At 48 kHz each MADI port carries 64 channels, so 128 outputs need two of the XT's MADI ports; `feral-engine devices` shows how many channels the driver presents, and `firstOutputChannel` picks where the engine's outputs start. To play pink noise at -20 dB RMS on every output, with nothing plugged in:

```json
{
  "device": "MADIface XT",
  "bufferFrames": 64,
  "inputs": 1,
  "outputs": 128,
  "routes": [ { "inputs": 1, "outputs": "1-128" } ],
  "testSignal": "pink"
}
```

Watch the outputs on TotalMix's meters. Set `"testSignal": "off"` and reload to use a real source on the input instead (`firstInputChannel` picks which device input).

For a straight 128-channel passthrough, leave out `inputs`, `outputs` and `routes`. The log line at start says how many engine channels found a device channel, the buffer size the device accepted and the latency it reports; every 10 seconds the engine logs a warning if any buffer ran late (over 80 % of its time), Core Audio reported an overload, or a buffer was skipped, and every 5 minutes it logs a status line.

### Hearing the renderers on the rig

`examples/stage-test.json` is a test layout on the XT's first 26 outputs: a Delay group of 8 mains, 4 front fills and 4 delays, a VBAP ring of 8 overheads, and 2 subs on the LFE send. Its test source plays pink noise and walks a 12 m circle from the stage lip into the house every 20 s, so you hear the delays glide and crossfade and the levels move:

```sh
cp ~/Library/Application\ Support/Feral/engine.json ~/Desktop/engine-backup.json   # keep yours
cp examples/stage-test.json ~/Library/Application\ Support/Feral/engine.json
./scripts/engine.sh reload
```

On TotalMix's meters the level walks across the mains as the source circles, the front fills lead when it is near the lip, the delays take over when it is deep in the house, and the overhead nearest the source is loudest. Solo two neighbouring outputs on the XT's phones to hear the movement: a gliding delay is a slight pitch bend, never a click. `./scripts/engine.sh log` shows the groups (the overheads as a 2D VBAP ring) and the tap count; `feral-cli taps` and `impulse` give the same layout's numbers offline. Copy `~/Desktop/engine-backup.json` back and reload to return to your own settings.

## Checking the renderers offline: feral-cli

`feral-cli` renders through the same core the engine plays live, faster than real time.

```sh
swift run -c release feral-cli check                                    # the known-answer checks
swift run -c release feral-cli taps --config examples/stage-test.json   # every source's gain and delay per speaker
swift run -c release feral-cli impulse --config examples/stage-test.json --source 1
swift run -c release feral-cli render --config examples/stage-test.json --seconds 20 ~/Desktop/orbit.wav
```

`check` plays generated signals through the core and compares the results with values worked out by hand from the design's formulas: arrival times and levels from the Delay renderer, the fractional delay's interpolation, the glide's rate, the crossfade's shape, gain ramps, the group crossfade, VBAP in 2D, 3D and an open dome, VBAP width, DBAP, and each part of the output processing. `impulse` gives each output's arrival (its loudest sample) and level (the energy of what it received, so it includes the speaker's trim and EQ). `taps` and `impulse` take the installed `engine.json` when `--config` is left out, so you can check a layout before reloading the engine. `render` writes a 32-bit float WAV with one channel per output; give it an input WAV (one channel per engine input) before the output file, or leave it out to render the config's test signal.

## Not yet

Milestone 2 does not have the show file and journal, the Mac app, OSC control, render worker threads, show mode or the backup engine; they follow the milestones in the design. Delay rendering runs on the one audio thread: 128 sources each through 32 delayed speakers, with full processing on 128 outputs, took about 0.5 ms of a 64-frame buffer's 1.33 ms on GitHub's Apple-silicon CI runner (the timing test in `swift test -c release` prints it for your Mac); a Delay group feeding all 128 speakers from all 128 sources is the case the design's render workers are for. "Freeze delays while tracking" waits for tracking (milestone 5).
