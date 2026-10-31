# Feral

In-house spatial audio engine for immersive live sound, on macOS. The design is in the [v1 technical design](https://claude.ai/artifact/313W4TBPo6gruTH6rBM8qq) and the background in the [platforms research](https://claude.ai/artifact/DeXcLoQPN3MHfYYRwwTGy9).

This is **milestone 4, control**, on top of milestone 1's engine skeleton, milestone 2's renderers and milestone 3's show file and app: a headless `feral-engine` process that opens one Core Audio device and renders up to 128 sources to 128 speakers through Delay, VBAP and DBAP speaker groups, with per-speaker processing, and is restarted by launchd if it crashes. Sources, speakers and groups now live in a **show file** (a `.feralshow` package) with **snapshots**, a **cue list** and a **journal** of every change, and the **Feral Mac app** shows the layout on a plan and moves sources with the mouse. QLab, consoles and anything else can now drive the engine: **OSC** in Feral's own namespace and in **ADM-OSC**, a **trigger map** in the show that turns MIDI program changes, notes, CCs, MIDI Show Control or any OSC message into cues, and **position owners** so QLab and cues never fight over a source (see [OSC, MIDI and the trigger map](#osc-midi-and-the-trigger-map)).

## What's here

| Part | Contents |
| --- | --- |
| `Sources/FeralCore` | The real-time render core in C++20: render states, per-source delay lines, gain ramps, delay glides and crossfades, per-output processing, and the lock-free swap between the control and audio threads. Also the renderers' geometry (`include/feral_geometry.h`): Delay, VBAP (2D pairs, 3D triangulation with virtual speakers, MDAP width) and DBAP, and EQ design. No Apple APIs, so it builds and tests on Linux. Swift reaches it through the C API in `include/feral_core.h`. |
| `Sources/FeralCoreAudio` | The Core Audio IOProc, in C++ so no Swift runs on the audio thread. It maps the device's streams (mono or interleaved) to engine channels. macOS only. |
| `Sources/FeralScene` | Engine settings (`engine.json`), the fixed routing, the show (sources, speakers, groups, snapshots, cues), its `.feralshow` package and journal, the commands that change it, snapshot fades, and `SpatialRenderer`, which turns the layout into render states. |
| `Sources/FeralControl` | The control link between the engine and the app or `feral-cli`: one JSON message per line over TCP, port 9100. OSC (reading and writing packets, the UDP server on port 9200), MIDI (a byte-stream parser with MIDI Show Control, and Core MIDI input with a virtual "Feral" destination), and `ControlMapper`, which turns OSC, ADM-OSC, MIDI and the trigger map into engine actions and changes back into OSC for subscribers. |
| `Sources/FeralApp` | The Feral Mac app (SwiftUI): the plan, the cue list with GO, snapshots, and an inspector for sources, speakers, snapshots and cues. |
| `Sources/FeralOffline`, `Sources/feral-cli` | Offline rendering through the same core, WAV files, and the known-answer checks: `feral-cli check`, `taps`, `impulse` and `render`. Show files: `show import`, `show info`. The running engine from Terminal: `status`, `go`, `recall`, `move`, `store`, `cue`, `stop`, `save`, `release`, `trigger`, `admbox`; `osc` and `osc-watch` to send and watch OSC, `midi` to send MIDI. |
| `Sources/FeralIO` | Core Audio device list, opening one device, and keeping it open: if it disappears, changes sample rate or changes its channels, the engine keeps its state and reopens it every second until it is back. macOS only. |
| `Sources/feral-engine` | The engine process. |
| `launchd/local.feral.engine.plist` | The launchd agent: starts at login, restarts within about a second after a crash. |
| `scripts/` | `build-engine-app.sh` (bundle), `install-engine.sh` (install or update the agent), `engine.sh` (status, log, reload, restart, stop, crash test), `build-app.sh` (the Mac app). |
| `examples/stage-test.json`, `examples/stage-test.feralshow` | Engine settings and a show for a 26-speaker test layout: a Delay group (front line, fills, delays), a VBAP overhead ring, two subs on the LFE send, a pink-noise test source, and five cues that walk it around the venue. |
| `Tests/` | OSC packets (known bytes, malformed packets and a 20,000-packet fuzz), the MIDI parser and MSC, Feral's OSC namespace, ADM-OSC, the trigger map and the echo to subscribers; the show file, journal replay, commands, snapshots, fades and cue order; the control link's messages and (macOS) a real connection; from milestone 2, the known-answer checks, delay taps, spatial settings and WAV files; from milestone 1, the matrix and ramps, the state swap under concurrent publishing (run under the thread sanitizer on Linux CI), a timing check for a dense 128 by 128 matrix, and the IOProc on hand-made mono and interleaved buffer lists (macOS). |

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
| `show` | `Shows/Default.feralshow` | The show to play: a `.feralshow` package, absolute, from `~`, or relative to engine.json's folder. With groups in the show, the engine renders its sources to them, and `routes` only adds fixed feeds on top (no passthrough) |
| `controlAddress` | `127.0.0.1` | Where the app and `feral-cli` reach the engine. `127.0.0.1` is this Mac only; `0.0.0.0` lets an app on another Mac connect. Needs an engine restart |
| `controlPort` | 9100 | The control link's TCP port |
| `oscAddress` | `0.0.0.0` | Where OSC is read: `0.0.0.0` is any network (QLab or a console on another machine), `127.0.0.1` this Mac only. Needs an engine restart |
| `oscPort` | 9200 | The UDP port OSC is read on; 0 turns OSC off |
| `midi` | true | Read MIDI for the trigger map and MIDI Show Control |
| `midiInputs` | every source | The MIDI sources to listen to, by name or part of one: `["IAC", "SD7"]`. The engine's own "Feral" destination always listens |
| `speakers`, `groups`, `sources`, `lfeOutputs` | none | Milestone 2's layout keys. They are only read once, to make the first show (below); after that the show holds the layout |
| `airTemperatureC` | 20 | Sets the speed of sound for Delay groups |
| `delayGlidePercent`, `delayJumpMS`, `delayCrossfadeMS` | 0.5, 5, 30 | A moving delay glides at most this fast (as a pitch shift); a jump bigger than `delayJumpMS` crossfades instead, over `delayCrossfadeMS` |
| `groupCrossfadeMS` | 50 | How long a reload's group, send or renderer changes take |
| `testMotion` | none | Moves one source by itself: `{ "source": 1, "shape": "circle", "center": [0, 6, 1.6], "radius": 6, "seconds": 20 }`, or `"shape": "line"` with `"from"` and `"to"` |

Milestone 2's layout keys, kept here because `feral-cli show import` and the engine's first start read them (the show file uses the same fields, with ids):

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

## The show file

A show is one `.feralshow` package (a folder): `show.json` holds the sources, groups, snapshots and cues; `system.json` holds the speakers and their system layer (alignment delay, EQ, trim, polarity, limiter, mute), which snapshots and cues never touch; `journal/journal.jsonl` holds every change since the last save, one line each. Every object has a stable id, which the files use to refer to each other, and a number for people, so renumbering never breaks a cue.

- **Opening**: the engine plays the show `engine.json` names (`"show"`), or `Shows/Default.feralshow` next to engine.json. If that show does not exist yet, the engine makes it from engine.json's own `speakers`, `groups` and `sources`, so a milestone 2 layout carries over by itself on the first start. After that, edit the layout in the show (or the app), not in engine.json.
- **Every change is journaled.** The app and `feral-cli` change the show only through the engine, which writes each change to the journal within 0.1 s. After a crash, launchd restarts the engine, it replays the journal and is back where it was, unsaved changes included.
- **Saving** (the app's Save button, ⌘S, or `feral-cli save`) writes `show.json` and `system.json` and empties the journal.
- **Switching shows**: change `"show"` in engine.json and `./scripts/engine.sh reload`. The old show's unsaved changes stay in its journal and come back when it is opened again.

**Snapshots** store some or all sources' position, gain, mute, width, sends and LFE send. Recalling one fades every stored value from where it is over the snapshot's fade time (or the cue's) with a linear, S-curve or exponential shape: positions in a straight line across the venue, levels in dB, a send that is added or removed fades from or to -60 dB, unmuting happens at the start and muting at the end. Moving a source by hand (or from another cue) during a fade takes it out of the fade.

**Cues** are numbered like QLab's (1, 2, 2.5, 10). A cue recalls a snapshot, with its own fade time and curve if set; auto-follow runs the next cue as soon as its fade ends. GO runs the next cue after the current one.

## The Feral app

```sh
./scripts/build-app.sh        # builds build/Feral.app
open build/Feral.app          # or copy it to /Applications
```

The app connects to the engine on this Mac (Feral > Settings to reach another Mac's engine) and shows its show: the plan (stage at the top, audience below, 1 m grid) with speakers coloured by group and sources as numbered dots. Drag a source to move it; the engine renders it as you drag. The sidebar has the GO button (⌘↩) with the current and next cue, the cue list, the snapshots (Store, Recall) and the sources and speakers. Select anything to edit it on the right: a source's name, position, gain, mute, width and sends; a speaker's position and system layer; a snapshot's name, fade and curve; a cue's number, snapshot, fade and auto-follow. "Move speakers" in the toolbar lets the plan drag speakers too. The engine keeps playing if the app quits or crashes.

## Trying it on the rig

This plays the example show on the XT's first 26 outputs, with pink noise as the test source.

1. Update the engine (it keeps your engine.json) and back up your settings:

   ```sh
   cd Feral && git pull
   ./scripts/install-engine.sh
   cp ~/Library/Application\ Support/Feral/engine.json ~/Desktop/engine-backup.json
   ```

2. Copy the example show and its settings into place, and reload:

   ```sh
   mkdir -p ~/Library/Application\ Support/Feral/Shows
   cp -R examples/stage-test.feralshow ~/Library/Application\ Support/Feral/Shows/
   sed 's|"stage-test.feralshow"|"Shows/stage-test.feralshow"|' examples/stage-test.json > ~/Library/Application\ Support/Feral/engine.json
   ./scripts/engine.sh reload
   ./scripts/engine.sh log      # look for "show: Stage test" and "control: listening"; Ctrl-C to stop
   ```

3. From Terminal, check the engine and run the cues (watch TotalMix's meters):

   ```sh
   swift run -c release feral-cli status    # the show, current and next cue, the audio device
   swift run -c release feral-cli go        # cue 1: the test source to centre stage
   swift run -c release feral-cli go        # cue 2: walks to stage left over 6 s
   swift run -c release feral-cli go        # cue 3: into the house over 10 s, then auto-follows cue 3.5 to stage right
   swift run -c release feral-cli go        # cue 4: home over 4 s
   swift run -c release feral-cli move 1 -6 10    # put source 1 at x -6, y 10
   swift run -c release feral-cli store "My spot" --fade 3   # store it as snapshot 5
   swift run -c release feral-cli cue 5 5          # add cue 5 that recalls it
   swift run -c release feral-cli go 1 && swift run -c release feral-cli go 5
   ```

4. Open the app (`./scripts/build-app.sh && open build/Feral.app`). Drag the test source around the plan and listen; press GO; store a snapshot and recall it. The title bar says how many changes are unsaved.

5. Crash test: `./scripts/engine.sh crash`, then `feral-cli status`. The source is where you left it and the unsaved changes are still listed (the journal was replayed). The app reconnects by itself.

6. Save (⌘S in the app, or `feral-cli save`), then `swift run -c release feral-cli show info` lists what the show holds.

To go back: `cp ~/Desktop/engine-backup.json ~/Library/Application\ Support/Feral/engine.json` and `./scripts/engine.sh reload`. Your own layout from milestone 2 is in `~/Library/Application Support/Feral/Shows/Default.feralshow` (made on the first start of this version).

For milestone 2's orbiting test source, add `"testMotion": { "source": 1, "shape": "circle", "center": [0, 6, 1.6], "radius": 6, "seconds": 20 }` to engine.json; it moves the source on input 1 (not journaled) and the app shows it moving.

## Without the rig: BlackHole and Max

BlackHole (a virtual audio device) works as the engine's device: it is a single Core Audio device, not an aggregate, with 32-bit float streams. Whatever any app plays on BlackHole's output channel n comes back on its input channel n, so the engine's inputs and outputs must use different channels or the engine hears itself. `examples/blackhole.json` (for BlackHole 64ch) does this: engine inputs 1-2 are BlackHole channels 1-2, and the 26 outputs are channels 33-58.

```sh
cp ~/Library/Application\ Support/Feral/engine.json ~/Desktop/engine-backup.json
mkdir -p ~/Library/Application\ Support/Feral/Shows
cp -R examples/stage-test.feralshow ~/Library/Application\ Support/Feral/Shows/
cp examples/blackhole.json ~/Library/Application\ Support/Feral/engine.json
./scripts/engine.sh reload && ./scripts/engine.sh log   # "running on BlackHole 64ch", outputs 26 of 26 connected
```

In Max, set Audio Status to BlackHole 64ch at 48 kHz. Meter (or listen to) `adc~` inputs 33-58: those are the engine's outputs 1-26. To feed the engine a real signal, set `"testSignal": "off"`, reload, and play into `dac~` outputs 1-2: they are engine inputs 1-2 (sources 1 and 2). Keep Max's other outputs silent, especially 33-58, which would add into what you meter. "Feral Engine" needs microphone access to read BlackHole's inputs, as with any interface.

`feral-engine devices` gives the exact name and channel count. With BlackHole 16ch, the 26-output example does not fit: use `"outputs": 14`, `"firstOutputChannel": 3` and a smaller show. With 128ch you can go up to 64 in and 64 out. BlackHole runs on its own clock, which is fine for testing but is not what a show would use.

## OSC, MIDI and the trigger map

The engine reads OSC on UDP port 9200 (`oscPort`) and MIDI from every MIDI source on the Mac, plus its own virtual MIDI destination called **Feral**. Sources, snapshots and cues are addressed by the numbers the app shows.

| OSC address | Arguments | What it does |
| --- | --- | --- |
| `/feral/go` | [cue] | GO: the next cue, or that cue |
| `/feral/cue/{n}/go` | | Run cue n (`/feral/cue/12.5/go` works) |
| `/feral/stop` | | Stop every running fade |
| `/feral/snapshot/{n}/recall` | [seconds] | Recall snapshot n over its own fade time, or this one |
| `/feral/snapshot/store` | [name] | Store every source as a new snapshot |
| `/feral/save` | | Save the show |
| `/feral/source/{n}/xyz` | x y z | Move source n (metres, venue frame); also `/xy x y`, `/x`, `/y`, `/z` |
| `/feral/source/{n}/gain`, `/mute`, `/width`, `/lfe` | dB, 0 or 1, degrees, dB or "off" | Its level, mute, VBAP width and LFE send |
| `/feral/source/{n}/send/{group}` | dB | A send level; the group by number or name |
| `/feral/source/{n}/release` | | Hand the source's position back to cues |
| `/feral/subscribe` | [port] ["adm"] | Send me every change, to this port (else the port the message came from), in ADM-OSC if asked |
| `/feral/unsubscribe` | [port] | |
| `/feral/ping` | anything | Answers `/feral/pong` with the same arguments |
| `/adm/obj/{n}/xyz`, `/x`, `/y`, `/z` | -1 to 1 | ADM-OSC position of source n, mapped onto the show's ADM box |
| `/adm/obj/{n}/aed`, `/azim`, `/elev`, `/dist` | degrees, degrees, 0 to 1 | ADM-OSC polar position (azimuth 0 is the front, positive to the left) |
| `/adm/obj/{n}/gain`, `/mute`, `/w` | linear, 0 or 1, 0 to 1 | Level, mute, width (1 is 180 degrees) |

Subscribers get `/feral/source/{n}/xyz`, `/gain`, `/mute`, `/width`, `/send/{group}` and `/lfe` whenever they change (from the app, a cue's fade, OSC or anything else), and `/feral/cue/current` and `/feral/cue/next` (number, name) when the cue list moves. A subscription lasts until `/feral/unsubscribe` or an engine restart. A message the engine cannot use is logged (once every 10 s per address) and answered with `/feral/error`; malformed packets are dropped without stopping anything.

**ADM-OSC box.** ADM-OSC positions run from -1 to 1 around the listener: x from the audience's left to their right, y from the back to the front (the stage), z from bottom to top. Feral maps that cube onto a box in the venue, by default x -10 to 10, y -2 to 20 and z 0 to 10 metres. Because Feral's x runs to stage right (the audience's left) and its y towards the audience, ADM's left lands on +x and ADM's front on the stage side. Set the box with `feral-cli admbox MINX MINY MINZ MAXX MAXY MAXZ`.

**Who moves a source.** Each source's position has one owner at a time: cues (the default, which includes the app and `feral-cli`), OSC, or later tracking. The newest one takes over. Once QLab (or any OSC) moves a source, cues and snapshots leave that source's position alone, while still setting its gain, mute and sends, so a QLab fade and a cue never fight. The source goes back to cues when you drag it in the app, move it with `feral-cli move`, press **Hand back to cues** in its inspector, run `feral-cli release N` or send `/feral/source/N/release`, or when a cue with **Take sources back from QLab or tracking** on runs. `feral-cli status` lists the sources OSC owns. Owners are not saved: after a restart every source belongs to cues.

**The trigger map** lives in the show (`show.json`, under `control`), so it travels with the production. Each trigger is a message in and an action out; in the action, `{value}` stands for the incoming number (the program number 1 to 128, the note, the CC value, the MSC cue number or the OSC message's first argument).

```sh
feral-cli trigger add program 5 go 12            # program change 5 (any channel) runs cue 12
feral-cli trigger add program any go {value}     # every program change runs the cue with its number
feral-cli trigger add note 60 recall 3 --fade 2  # note 60 recalls snapshot 3 over 2 s
feral-cli trigger add cc 20 127 stop --channel 16
feral-cli trigger add osc /digico/snapshot any go {value}   # any OSC address a console sends
feral-cli trigger list
feral-cli trigger remove 2
```

In `show.json` the same triggers read `{ "on": { "midiProgram": { "program": 5 } }, "action": { "go": { "cue": "12" } } }`; a field left out (`channel`, `program`, `value`) matches anything, and `"enabled": false` turns one off.

**DiGiCo.** Depending on the desk's software, its snapshots send MIDI program changes or OSC. Program changes need only `trigger add program any go {value}` (or one trigger per snapshot); for OSC, look in the engine's log for the line `osc: nothing listens for /...` the first time the desk fires a snapshot, and add a trigger for that address.

**MIDI Show Control.** Without a trigger of its own, MSC GO (with or without a cue number), TIMED_GO and RESUME run cues and STOP, ALL_OFF and GO_OFF stop fades. The engine answers every device id unless the show sets `"mscDeviceID"` under `control` (then that id and 127, the all-call). A trigger for an MSC command replaces the built-in action.

**QLab.** In QLab 5, add a Network patch: type OSC, destination the engine Mac's address (127.0.0.1 if QLab is on the same Mac), port 9200. Then a Network cue with the message `/feral/cue/12/go` fires cue 12, and a Network cue with `/feral/source/1/xyz` and a fade sends the position over time, so QLab moves the source smoothly (the engine follows each value it receives).

### Testing control without the rig

With the engine on BlackHole as above (`examples/blackhole.json`), everything here can be tested on the laptop. Update first:

```sh
cd Feral && git pull
./scripts/install-engine.sh
./scripts/engine.sh log      # look for "osc: listening on 0.0.0.0 UDP port 9200" and "midi: listening to ..."; Ctrl-C to stop
```

1. Watch what the engine sends, in a second Terminal window:

   ```sh
   swift run -c release feral-cli osc-watch
   ```

2. In the first window, move source 1 by OSC and listen (or meter channels 33-58 in Max):

   ```sh
   swift run -c release feral-cli osc /feral/ping
   swift run -c release feral-cli osc /feral/source/1/xyz -6 4 1.6
   swift run -c release feral-cli osc /adm/obj/1/azim -45
   swift run -c release feral-cli status          # "live: source 1 Test position from OSC (QLab)"
   swift run -c release feral-cli go 2            # cue 2 does not move source 1: OSC owns it
   swift run -c release feral-cli release 1
   swift run -c release feral-cli go 2            # now it does
   ```

3. Fire cues from MIDI, as a console's snapshots would:

   ```sh
   swift run -c release feral-cli trigger add program any go {value}
   swift run -c release feral-cli midi program 3   # runs cue 3
   swift run -c release feral-cli midi msc go 4    # MSC GO cue 4
   ```

4. From Max: `[udpsend 127.0.0.1 9200]` sends OSC (a message box `/feral/source/1/xyz $1 $2 1.6` fed by a `[pictslider]` moves the source as you drag). `[udpreceive 9300]` with `/feral/subscribe 9300` sent once shows every change. `[midiout]` set to the **Feral** destination (or the IAC bus) sends program changes and notes for the trigger map.

5. If QLab is on the laptop, the QLab steps above work as they would at a show.

The app shows who owns each source's position in its inspector, and the cue inspector has the **Take sources back from QLab or tracking** switch.

## Checking the renderers offline: feral-cli

`feral-cli` renders through the same core the engine plays live, faster than real time.

```sh
swift run -c release feral-cli check                                    # the known-answer checks
swift run -c release feral-cli taps --config examples/stage-test.json   # every source's gain and delay per speaker
swift run -c release feral-cli impulse --config examples/stage-test.json --source 1
swift run -c release feral-cli render --config examples/stage-test.json --seconds 20 ~/Desktop/stage.wav
swift run -c release feral-cli show info --config examples/stage-test.json
swift run -c release feral-cli show import ~/Desktop/Mine.feralshow --config my-old-engine.json   # a milestone 2 layout as a show
```

`check` plays generated signals through the core and compares the results with values worked out by hand from the design's formulas: arrival times and levels from the Delay renderer, the fractional delay's interpolation, the glide's rate, the crossfade's shape, gain ramps, the group crossfade, VBAP in 2D, 3D and an open dome, VBAP width, DBAP, and each part of the output processing. `impulse` gives each output's arrival (its loudest sample) and level (the energy of what it received, so it includes the speaker's trim and EQ). `taps` and `impulse` take the installed `engine.json` and its show when `--config` is left out (`--show PATH` picks another show), so you can check a layout before reloading the engine. `render` writes a 32-bit float WAV with one channel per output; give it an input WAV (one channel per engine input) before the output file, or leave it out to render the config's test signal.

## Not yet

Milestone 4 does not have show mode, tracking, the iPad remote, render worker threads or the backup engine; they follow the milestones in the design. OSC is UDP only (no OSC over TCP yet), the trigger map is edited with `feral-cli` or in `show.json` (not yet in the app), and the engine does not yet reply to QLab's own OSC to show the live cue (subscribers get `/feral/cue/current` instead). The app's interface gets its next round of work after this milestone. From the design's milestone 3 list, importing the system layer from Measure's alignment results, a 3D view, editing EQ and limiters in the app, adding and removing speakers, groups and sources in the app, and New/Open/Save As are still to do: speakers, groups and sources can be added by editing the show's JSON (or importing an engine.json layout), and EQ and limiters in `system.json`. The app's control link stays JSON over TCP on port 9100; OSC drives the same engine actions. The show's content hash for the backup engine comes with the backup engine (milestone 6). Delay rendering runs on the one audio thread: 128 sources each through 32 delayed speakers, with full processing on 128 outputs, took about 0.5 ms of a 64-frame buffer's 1.33 ms on GitHub's Apple-silicon CI runner (the timing test in `swift test -c release` prints it for your Mac); a Delay group feeding all 128 speakers from all 128 sources is the case the design's render workers are for.
