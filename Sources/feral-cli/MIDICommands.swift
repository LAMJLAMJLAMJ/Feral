#if canImport(CoreMIDI)
import FeralControl
import FeralScene
import Foundation

// feral-cli midi: sends MIDI to the engine's "Feral" destination (or --to another), as a console would,
// for testing without one.
//
//   feral-cli midi program 5 [--channel 1]
//   feral-cli midi note 60 [--channel 1]
//   feral-cli midi cc 20 127 [--channel 1]
//   feral-cli midi msc go [CUE]       also msc stop, msc resume
//   feral-cli midi list               the MIDI destinations on this Mac

func runMIDICommand(_ args: [String]) {
    let ch = channel ?? 1
    guard (1...16).contains(ch) else { fail("--channel must be from 1 to 16") }
    func int(_ i: Int, _ range: ClosedRange<Int>, _ what: String) -> Int {
        guard i < args.count, let n = Int(args[i]), range.contains(n) else {
            fail("midi \(args.first ?? ""): \(what) must be from \(range.lowerBound) to \(range.upperBound)")
        }
        return n
    }
    let message: MIDIMessage
    switch args.first ?? "" {
    case "list":
        for d in MIDISender.destinations() { print(d) }
        return
    case "program": message = .programChange(channel: ch, program: int(1, 1...128, "the program"))
    case "note": message = .noteOn(channel: ch, note: int(1, 0...127, "the note"), velocity: 100)
    case "cc": message = .controlChange(channel: ch, controller: int(1, 0...127, "the controller"), value: int(2, 0...127, "the value"))
    case "msc":
        guard args.count >= 2, let command = MSCCommand(rawValue: args[1]) else {
            fail("midi msc needs a command: " + MSCCommand.allCases.map(\.rawValue).joined(separator: ", "))
        }
        message = .showControl(MSCMessage(deviceID: 127, command: command, cue: args.count > 2 ? args[2] : nil))
    default:
        fail("midi program N, midi note N, midi cc N V, midi msc go [CUE], or midi list")
    }
    do {
        try MIDISender.send(message.bytes, to: midiDestination)
        print("sent \(message) to \(midiDestination)")
    } catch { fail("\(error)") }
}
#endif
