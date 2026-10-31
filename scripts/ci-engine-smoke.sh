#!/bin/bash
# CI: runs feral-engine with the example show and no audio device, drives it with feral-cli over the
# control link, kills it as a crash would, and checks the restarted engine replays its journal.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(swift build -c release --show-bin-path)"
DIR="$(mktemp -d)"
PORT=9177
cp -R examples/stage-test.feralshow "$DIR/"
sed -e 's|"MADIface XT"|"no such device"|' -e "s|\"show\"|\"controlPort\": $PORT, \"show\"|" examples/stage-test.json > "$DIR/engine.json"
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
cli save
test ! -s "$DIR/stage-test.feralshow/journal/journal.jsonl"
grep -q "CI spot" "$DIR/stage-test.feralshow/show.json"
kill "$ENGINE"
wait "$ENGINE" 2>/dev/null || true
echo "--- engine log"
cat "$DIR/engine.log"
echo "engine smoke test passed"
