#if canImport(SwiftUI) && os(macOS)
import FeralControl
import FeralScene
import Foundation
import Network
import SwiftUI

/// The control monitor's lines: every OSC and MIDI message the engine hears and what it did, plus the
/// test messages this window sends and the engine's OSC replies to them.
final class ControlMonitor: ObservableObject {
    struct Line: Identifiable {
        enum Kind: String { case oscIn = "OSC in", midiIn = "MIDI in", sent = "sent", reply = "reply", note = "note" }
        let id: Int
        let time: Date
        let kind: Kind
        let from: String
        let message: String
        let result: String
        let handled: Bool
    }

    static let maxLines = 1000

    @Published private(set) var lines: [Line] = []
    @Published var paused = false
    private var nextID = 0
    private var sender: OSCTestSender?

    /// What the engine says it heard.
    func heard(_ activity: [ControlActivity], dropped: Int) {
        guard !paused else { return }
        var new = activity.map { a in
            make(a.kind == .osc ? .oscIn : .midiIn, Date(timeIntervalSince1970: a.time), a.from, a.message, a.result, a.handled)
        }
        if dropped > 0 {
            new.append(make(.note, Date(), "engine", "\(dropped) more message(s) left out", "too many at once to list them all", true))
        }
        append(new)
    }

    func clear() { lines = [] }

    private func make(_ kind: Line.Kind, _ time: Date, _ from: String, _ message: String, _ result: String,
                      _ handled: Bool) -> Line {
        nextID += 1
        return Line(id: nextID, time: time, kind: kind, from: from, message: message, result: result, handled: handled)
    }

    private func append(_ new: [Line]) {
        guard !new.isEmpty else { return }
        lines.append(contentsOf: new)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    private func note(_ kind: Line.Kind, _ from: String, _ message: String, _ result: String, _ handled: Bool) {
        append([make(kind, Date(), from, message, result, handled)])
    }

    /// Sends an OSC message typed as in feral-cli osc ("/feral/source/1/xyz 2 6 1.6") to the engine's
    /// OSC port over UDP, as QLab or a console would. Replies show up as lines.
    func sendOSC(_ text: String, host: String, port: Int?) {
        let words = text.split(separator: " ").map(String.init)
        guard let address = words.first, address.hasPrefix("/") else {
            note(.sent, "this app", text, "an OSC message starts with an address such as /feral/go", false)
            return
        }
        guard let port, port > 0 else {
            note(.sent, "this app", text, "the engine's OSC is off or not listening yet", false)
            return
        }
        if sender == nil || sender?.host != host || sender?.port != port {
            sender?.stop()
            let s = OSCTestSender(host: host, port: port)
            s.onReply = { [weak self] m in self?.note(.reply, "\(host):\(port)", m.description, "", true) }
            s.onFailure = { [weak self] why in self?.note(.note, "this app", "OSC", why, false) }
            sender = s
        }
        let m = OSCMessage(address, words.dropFirst().map(Self.argument))
        sender?.send(m)
        note(.sent, "this app", m.description, "to \(host) UDP port \(port)", true)
    }

    /// Sends MIDI to the engine's "Feral" destination (the engine must run on this Mac).
    func sendMIDI(_ message: MIDIMessage) {
        let text = message.description
        note(.sent, "this app", text, "to the \"\(MIDIInput.destinationName)\" MIDI destination", true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try MIDISender.send(message.bytes, to: MIDIInput.destinationName)
            } catch {
                DispatchQueue.main.async { self?.note(.note, "this app", text, "\(error)", false) }
            }
        }
    }

    /// As feral-cli reads arguments: a whole number is an int, a number with a point a float, else text.
    static func argument(_ text: String) -> OSCValue {
        if let i = Int32(text) { return .int(i) }
        if let f = Float(text), f.isFinite { return .float(f) }
        return .string(text)
    }
}

/// A UDP flow to the engine's OSC port that also reads what the engine answers (/feral/pong,
/// /feral/error). Callbacks run on the main queue.
final class OSCTestSender {
    let host: String
    let port: Int
    private let connection: NWConnection
    var onReply: ((OSCMessage) -> Void)?
    var onFailure: ((String) -> Void)?

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        let params = NWParameters.udp
        if host == "127.0.0.1" || host == "localhost" { params.requiredInterfaceType = .loopback }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 9200,
                                  using: params)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onFailure?("the OSC link failed: \(error)") }
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ m: OSCMessage) {
        connection.send(content: OSC.encode(m), completion: .contentProcessed { [weak self] error in
            if let error { self?.onFailure?("could not send: \(error)") }
        })
    }

    func stop() { connection.cancel() }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let messages = try? OSC.messages(in: data) { for m in messages { self.onReply?(m) } }
            if error == nil { self.receive() }
        }
    }
}

/// Window > Control monitor: what OSC and MIDI reach the engine and what it does with them, and test
/// messages to send it, so a console's or QLab's setup can be checked without them.
struct MonitorView: View {
    @ObservedObject var model: EngineModel
    @ObservedObject var monitor: ControlMonitor
    @State private var filter = Filter.all
    @State private var oscText = "/feral/ping"
    @State private var midiKind = MIDIKind.program
    @State private var midiNumber = 1
    @State private var midiValue = 127
    @State private var midiChannel = 1
    @State private var mscCue = ""
    @State private var follow = true

    enum Filter: String, CaseIterable { case all = "All", osc = "OSC", midi = "MIDI", problems = "Not handled" }
    enum MIDIKind: String, CaseIterable { case program = "Program change", note = "Note on", cc = "Control change", msc = "MSC GO" }

    private static let examples: [(String, String)] = [
        ("/feral/ping", "Is the engine there? It answers /feral/pong"),
        ("/feral/go", "GO: the next cue"),
        ("/feral/cue/1/go", "Run cue 1"),
        ("/feral/stop", "Stop every fade"),
        ("/feral/snapshot/1/recall 2", "Recall snapshot 1 over 2 s"),
        ("/feral/source/1/xyz 0 5 1.5", "Move source 1 (OSC takes it over from cues)"),
        ("/feral/source/1/gain -6", "Source 1 gain in dB"),
        ("/feral/source/1/release", "Hand source 1 back to cues"),
        ("/adm/obj/1/azim 30", "ADM-OSC: object 1 to 30 degrees"),
        ("/adm/obj/1/xyz 0.5 0.5 0", "ADM-OSC: object 1 in the ADM box"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            log
            Divider()
            senders
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Label(model.connected ? "Engine \(model.address)" : "Not connected", systemImage: "circle.fill")
                .foregroundStyle(model.connected ? Color.green : Color.red)
                .labelStyle(.titleAndIcon)
            Text("OSC: \(model.status?.osc.isEmpty == false ? model.status!.osc : "off")")
            Text("MIDI: \(model.status?.midi.isEmpty == false ? model.status!.midi : "off")").lineLimit(1)
            Spacer()
            Picker("Show", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 300).labelsHidden()
            Toggle("Pause", isOn: $monitor.paused).toggleStyle(.button)
            Button("Clear") { monitor.clear() }
        }
        .font(.callout)
        .padding(10)
    }

    private var shown: [ControlMonitor.Line] {
        switch filter {
        case .all: return monitor.lines
        case .osc: return monitor.lines.filter { $0.kind == .oscIn || $0.kind == .reply || ($0.kind == .sent && $0.message.hasPrefix("/")) }
        case .midi: return monitor.lines.filter { $0.kind == .midiIn || ($0.kind == .sent && !$0.message.hasPrefix("/")) }
        case .problems: return monitor.lines.filter { !$0.handled }
        }
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var log: some View {
        ScrollViewReader { proxy in
            List(shown) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.timeFormat.string(from: line.time)).foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
                    Text(line.kind.rawValue).font(.caption.bold()).foregroundStyle(color(line.kind)).frame(width: 56, alignment: .leading)
                    Text(line.message).font(.body.monospaced()).textSelection(.enabled).frame(minWidth: 220, alignment: .leading)
                    Image(systemName: line.handled ? "arrow.right" : "exclamationmark.triangle.fill")
                        .foregroundStyle(line.handled ? Color.secondary : Color.orange)
                    Text(line.result).foregroundStyle(line.handled ? Color.primary : Color.orange).lineLimit(2)
                    Spacer()
                    Text(line.from).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.callout.monospacedDigit())
                .id(line.id)
            }
            .overlay {
                if monitor.lines.isEmpty {
                    VStack(spacing: 6) {
                        Text("Nothing heard yet").font(.headline)
                        Text("Send OSC to the engine's port or MIDI to its \"Feral\" destination, from QLab, a console or Max, "
                             + "or with the test messages below.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    }
                }
            }
            .onChange(of: monitor.lines.last?.id) { id in
                if follow, let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom, alignment: .trailing) {
                Toggle("Follow newest", isOn: $follow).toggleStyle(.checkbox).font(.caption).padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(8)
            }
        }
    }

    private func color(_ kind: ControlMonitor.Line.Kind) -> Color {
        switch kind {
        case .oscIn: return .blue
        case .midiIn: return .purple
        case .sent: return .teal
        case .reply: return .green
        case .note: return .secondary
        }
    }

    private var senders: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send a test message").font(.headline)
            HStack {
                Text("OSC").frame(width: 40, alignment: .leading)
                TextField("/feral/go", text: $oscText)
                    .font(.body.monospaced())
                    .onSubmit(sendOSC)
                Menu("Examples") {
                    ForEach(Self.examples.indices, id: \.self) { i in
                        let e = Self.examples[i]
                        Button("\(e.0)    \(e.1)") { oscText = e.0 }
                    }
                }
                .frame(width: 110)
                Button("Send", action: sendOSC).keyboardShortcut(.defaultAction)
            }
            Text("Goes over UDP to \(model.host) port \(model.status?.oscPort.map(String.init) ?? "(not listening)"), "
                 + "as QLab's Network cues or a console send it. Arguments: whole numbers are ints, numbers with a point floats, "
                 + "anything else text.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("MIDI").frame(width: 40, alignment: .leading)
                Picker("", selection: $midiKind) { ForEach(MIDIKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 160)
                switch midiKind {
                case .program:
                    Stepper("Program \(midiNumber)", value: $midiNumber, in: 1...128)
                case .note:
                    Stepper("Note \(min(midiNumber, 127))", value: $midiNumber, in: 0...127)
                case .cc:
                    Stepper("CC \(min(midiNumber, 127))", value: $midiNumber, in: 0...127)
                    Stepper("value \(midiValue)", value: $midiValue, in: 0...127)
                case .msc:
                    TextField("cue (empty: the next)", text: $mscCue).frame(width: 150)
                }
                if midiKind != .msc {
                    Stepper("channel \(midiChannel)", value: $midiChannel, in: 1...16)
                }
                Spacer()
                Button("Send to \"\(MIDIInput.destinationName)\"", action: sendMIDI)
            }
            Text("MIDI goes to the engine's own \"\(MIDIInput.destinationName)\" destination, so the engine must run on this Mac. "
                 + "It only does something when the trigger map has a trigger for it (MSC GO works without one).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func sendOSC() {
        monitor.sendOSC(oscText.trimmingCharacters(in: .whitespaces), host: model.host, port: model.status?.oscPort)
    }

    private func sendMIDI() {
        let message: MIDIMessage
        switch midiKind {
        case .program: message = .programChange(channel: midiChannel, program: max(1, min(midiNumber, 128)))
        case .note: message = .noteOn(channel: midiChannel, note: min(midiNumber, 127), velocity: 100)
        case .cc: message = .controlChange(channel: midiChannel, controller: min(midiNumber, 127), value: midiValue)
        case .msc:
            let cue = mscCue.trimmingCharacters(in: .whitespaces)
            message = .showControl(MSCMessage(deviceID: 127, command: .go, cue: cue.isEmpty ? nil : cue))
        }
        monitor.sendMIDI(message)
    }
}
#endif
