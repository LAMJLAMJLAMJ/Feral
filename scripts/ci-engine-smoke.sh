#!/bin/bash
# CI: runs feral-engine with the example show and no audio device, drives it with feral-cli over the
# control link, OSC and MIDI, kills it as a crash would, and checks the restarted engine replays its
# journal.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(swift build -c release --show-bin-path)"
DIR="$(mktemp -d)"
PORT=9177
OSC_PORT=9277
cp -R examples/stage-test.feralshow "$DIR/"
sed -e 's|"MADIface XT"|"no such device"|' -e "s|\"show\"|\"controlPort\": $PORT, \"oscPort\": $OSC_PORT, \"show\"|" examples/stage-test.json > "$DIR/engine.json"
cat "$DIR/engine.json"
cli() { "$BIN/feral-cli" "$@" --config "$DIR/engine.json"; }

start_engine() {
    "$BIN/feral-engine" run --config "$DIR/engine.json" >>"$DIR/engine.log" 2>&1 &
    ENGINE=$!
    for _ in $(seq 1 50); do
        grep -q "control: listening" "$DIR/engine.log" && return 0
        sleep 0.2
    done
    cat "$DIR/engine.log"; echo "the engine did not start listening"; exit 1
}

start_engine
cli status
cli go
cli move 1 -6 10
cli store "CI spot" --fade 0
cli cue 9 5 --name "CI cue"
cli go 9

# OSC: a ping, a subscriber that hears a move, a move that takes the source from cues, and a trigger.
cli osc /feral/ping 42 | tee "$DIR/ping.txt"
grep -q "/feral/pong 42" "$DIR/ping.txt"
cli osc-watch --seconds 2 > "$DIR/watch.txt" &
WATCH=$!
sleep 0.5
cli osc /feral/source/2/xyz 3 7 1.5
cli osc /adm/obj/2/gain 0.5
wait "$WATCH"
cat "$DIR/watch.txt"
grep -q "/feral/source/2/xyz 3 7 1.5" "$DIR/watch.txt"
grep -q "/feral/source/2/gain -6.02" "$DIR/watch.txt"
cli status | tee "$DIR/status.txt"
grep -q "source 2 Vox position from OSC" "$DIR/status.txt"
cli trigger add osc /ci/fire any go 9
cli trigger list | grep -q "/ci/fire"
cli go 1
cli osc /ci/fire 1
sleep 0.3
cli status | grep "current 9"
# Malformed packets must not stop the engine.
head -c 3000 /dev/urandom > "$DIR/junk"
for i in $(seq 1 20); do
    head -c $((i * 37)) "$DIR/junk" | nc -u -w 0 127.0.0.1 "$OSC_PORT" || true
done
cli osc /feral/ping | grep -q pong

# MIDI through the engine's own "Feral" destination, where the runner has Core MIDI.
if "$BIN/feral-cli" midi list | grep -q "^Feral$"; then
    cli trigger add program any go "{value}"
    cli go 1
    cli midi program 9
    sleep 0.3
    cli status | grep "current 9"
else
    echo "no Core MIDI destination on this runner; MIDI skipped"
fi
# OSC still owns source 2, so the cues above left it where OSC put it. Hand it back.
cli release 2
cli status | tee "$DIR/status.txt"
if grep -q "position from OSC" "$DIR/status.txt"; then echo "source 2 was not handed back"; exit 1; fi
sleep 0.5   # let the journal flush (every 0.1 s)

# A crash: no chance to save or flush anything more.
kill -9 "$ENGINE"
wait "$ENGINE" 2>/dev/null || true
grep -c . "$DIR/stage-test.feralshow/journal/journal.jsonl"

start_engine
cli status | tee "$DIR/status.txt"
grep -q "unsaved change" "$DIR/status.txt"
cli show info --show "$DIR/stage-test.feralshow" | tee "$DIR/info.txt"
grep -q "CI spot" "$DIR/info.txt"
grep -q "9 CI cue" "$DIR/info.txt"
grep -q "at \[-6.0, 10.0, 1.6\]" "$DIR/info.txt"
grep -q "at \[3.0, 7.0, 1.5\]" "$DIR/info.txt"
cli save
test ! -s "$DIR/stage-test.feralshow/journal/journal.jsonl"
grep -q "CI spot" "$DIR/stage-test.feralshow/show.json"
kill "$ENGINE"
wait "$ENGINE" 2>/dev/null || true
echo "--- engine log"
cat "$DIR/engine.log"
echo "engine smoke test passed"
