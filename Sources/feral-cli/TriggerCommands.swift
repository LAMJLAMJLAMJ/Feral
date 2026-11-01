import FeralControl
import FeralScene
import Foundation

// feral-cli trigger and admbox: the show's trigger map and ADM-OSC box, changed in the running engine.
//
//   feral-cli trigger list
//   feral-cli trigger add program 5 go 12           a program change fires cue 12 (--channel N for one channel)
//   feral-cli trigger add program any go {value}    every program change fires the cue with its number
//   feral-cli trigger add note 60 recall 3 --fade 2
//   feral-cli trigger add cc 20 127 stop
//   feral-cli trigger add osc /digico/snapshot any go {value}
//   feral-cli trigger add msc go any go {value}
//   feral-cli trigger remove 2
//   feral-cli admbox                                 the box ADM-OSC's -1 to 1 spans
//   feral-cli admbox -10 -2 0 10 20 10              set it: min x y z, max x y z (metres)

/// A trigger from words, as in the list above.
func parseTrigger(_ words: [String]) -> Trigger {
    var w = words
    func next(_ what: String) -> String {
        guard !w.isEmpty else { fail("trigger add: \(what) is missing; see feral-cli help") }
        return w.removeFirst()
    }
    func number(_ what: String, _ range: ClosedRange<Int>) -> Int? {
        let t = next(what)
        if t == "any" { return nil }
        guard let n = Int(t), range.contains(n) else { fail("trigger add: \(what) must be from \(range.lowerBound) to \(range.upperBound), or any") }
        return n
    }
    if let c = channel, !(1...16).contains(c) { fail("--channel must be from 1 to 16") }
    let input: TriggerInput
    switch next("what to listen for (program, note, cc, osc or msc)") {
    case "program": input = .midiProgram(channel: channel, program: number("the program", 1...128))
    case "note": input = .midiNote(channel: channel, note: number("the note", 0...127))
    case "cc":
        guard let cc = number("the controller", 0...127) else { fail("trigger add cc needs a controller number") }
        input = .midiControl(channel: channel, controller: cc, value: number("the value", 0...127))
    case "osc":
        let address = next("the OSC address")
        guard address.hasPrefix("/") else { fail("an OSC address starts with /") }
        let value = next("the value (or any)")
        input = .osc(address: address, value: value == "any" ? nil : value)
    case "msc":
        let cmd = next("the MSC command (go, stop, resume... or any)")
        let command = cmd == "any" ? nil : MSCCommand(rawValue: cmd)
        if cmd != "any" && command == nil { fail("MSC commands: " + MSCCommand.allCases.map(\.rawValue).joined(separator: ", ")) }
        let cue = next("the cue number (or any)")
        input = .msc(command: command, cue: cue == "any" ? nil : cue)
    case let other:
        fail("trigger add: \(other)? Listen for program, note, cc, osc or msc")
    }
    let action: TriggerAction
    switch next("the action (go, recall or stop)") {
    case "go": action = .go(cue: w.isEmpty ? nil : w.removeFirst())
    case "recall": action = .recall(snapshot: next("the snapshot"), fadeSeconds: fade)
    case "stop": action = .stop
    case let other: fail("trigger add: \(other)? The action is go [CUE], recall SNAPSHOT or stop")
    }
    guard w.isEmpty else { fail("trigger add: \(w.joined(separator: " ")) is left over") }
    return Trigger(name: cueName, on: input, action: action)
}

func printTriggers(_ c: ControlSettings) {
    if c.triggers.isEmpty { print("no triggers; add one with feral-cli trigger add program 5 go 12") }
    for (i, t) in c.triggers.enumerated() {
        print("\(pad(String(i + 1), 3)) \(pad(t.on.description, 34)) -> \(t.action)" + (t.name.map { "  (\($0))" } ?? "")
              + (t.enabled ? "" : "  OFF"))
    }
    print("MSC: answers " + (c.mscDeviceID.map { "device \($0) and 127" } ?? "every device id"))
}

func printBox(_ b: ADMBox) {
    print("ADM-OSC box: x from \(b.max.x) (ADM -1, the audience's left) to \(b.min.x) (ADM +1)")
    print("             y from \(b.max.y) (ADM -1, the back) to \(b.min.y) (ADM +1, the front)")
    print("             z from \(b.min.z) (ADM -1) to \(b.max.z) (ADM +1), in metres")
}
