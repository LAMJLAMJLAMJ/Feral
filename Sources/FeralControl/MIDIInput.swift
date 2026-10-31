#if canImport(CoreMIDI)
import CoreMIDI
import Foundation

/// MIDI into the engine from Core MIDI: every MIDI source on the Mac (a console's USB or network
/// MIDI, the IAC bus), or only the ones named, plus a virtual destination called "Feral" that Max,
/// QLab or feral-cli can send to directly. Sources plugged in later are picked up. Messages arrive
/// on `queue`.
public final class MIDIInput {
    /// The virtual destination's name.
    public static let destinationName = "Feral"

    private let queue: DispatchQueue
    private let only: [String]?
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var destination = MIDIEndpointRef()
    private var connected: [MIDIEndpointRef] = []
    /// Source names by the id handed to Core MIDI with each connection (0 is the virtual destination).
    private var names: [Int: String] = [0: MIDIInput.destinationName]
    private var parsers: [Int: MIDIParser] = [:]
    private var generation = 0

    public var onMessage: ((MIDIMessage, String) -> Void)?
    public var onLog: ((String) -> Void)?

    /// `only`: the sources to listen to (a name or part of one); none listens to every source.
    public init(queue: DispatchQueue, only: [String]?) {
        self.queue = queue
        self.only = only
    }

    public func start() {
        let status = MIDIClientCreateWithBlock("Feral engine" as CFString, &client) { [weak self] note in
            guard note.pointee.messageID == .msgSetupChanged else { return }
            self?.queue.async { self?.connectSources() }
        }
        guard status == noErr else { onLog?("midi: cannot start Core MIDI (error \(status)); no MIDI in"); return }
        let read: MIDIReadBlock = { [weak self] list, refCon in
            let id = Int(bitPattern: refCon)
            let bytes = MIDIInput.bytes(of: list)
            self?.queue.async { self?.handle(bytes, from: id) }
        }
        if MIDIInputPortCreateWithBlock(client, "Feral in" as CFString, &port, read) != noErr {
            onLog?("midi: cannot make an input port; only the Feral destination listens")
        }
        let dest: MIDIReadBlock = { [weak self] list, _ in
            let bytes = MIDIInput.bytes(of: list)
            self?.queue.async { self?.handle(bytes, from: 0) }
        }
        if MIDIDestinationCreateWithBlock(client, MIDIInput.destinationName as CFString, &destination, dest) == noErr {
            onLog?("midi: virtual destination \"\(MIDIInput.destinationName)\" is open")
        } else {
            onLog?("midi: cannot make the \"\(MIDIInput.destinationName)\" destination")
        }
        queue.async { self.connectSources() }
    }

    public func stop() {
        for s in connected { MIDIPortDisconnectSource(port, s) }
        connected = []
        if destination != 0 { MIDIEndpointDispose(destination) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Connects to every source (or the ones named), again from scratch.
    private func connectSources() {
        guard port != 0 else { return }
        for s in connected { MIDIPortDisconnectSource(port, s) }
        connected = []
        generation += 1
        names = [0: MIDIInput.destinationName]
        parsers = [:]
        var list: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            guard source != 0 else { continue }
            let name = MIDIInput.name(of: source)
            if let only, !only.contains(where: { name.localizedCaseInsensitiveContains($0) }) { continue }
            let id = generation << 16 | (i + 1)
            if MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: id)) == noErr {
                connected.append(source)
                names[id] = name
                list.append(name)
            }
        }
        onLog?("midi: listening to " + (list.isEmpty ? "no MIDI sources" : list.joined(separator: ", "))
               + " and the \"\(MIDIInput.destinationName)\" destination")
    }

    private func handle(_ bytes: [UInt8], from id: Int) {
        guard let name = names[id] else { return } // from a connection made before a rescan
        var parser = parsers[id] ?? MIDIParser()
        let messages = parser.feed(bytes)
        parsers[id] = parser
        for m in messages { onMessage?(m, name) }
    }

    static func name(of object: MIDIObjectRef) -> String {
        var s: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &s) == noErr, let s else { return "MIDI \(object)" }
        return s.takeRetainedValue() as String
    }

    /// The bytes of every packet in a list, in order.
    static func bytes(of list: UnsafePointer<MIDIPacketList>) -> [UInt8] {
        var out: [UInt8] = []
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
        for packet in list.unsafeSequence() {
            let n = Int(packet.pointee.length)
            let start = UnsafeRawPointer(packet) + dataOffset
            out += UnsafeRawBufferPointer(start: start, count: n)
        }
        return out
    }
}

/// Sends MIDI to a destination by name (feral-cli midi, for tests without a console).
public enum MIDISender {
    /// The destinations on this Mac.
    public static func destinations() -> [String] {
        (0..<MIDIGetNumberOfDestinations()).map { MIDIInput.name(of: MIDIGetDestination($0)) }
    }

    public static func send(_ bytes: [UInt8], to name: String) throws {
        var client = MIDIClientRef()
        var port = MIDIPortRef()
        guard MIDIClientCreate("feral-cli" as CFString, nil, nil, &client) == noErr,
              MIDIOutputPortCreate(client, "feral-cli out" as CFString, &port) == noErr else {
            throw ControlError("cannot start Core MIDI")
        }
        defer { MIDIClientDispose(client) }
        guard let dest = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination)
            .first(where: { MIDIInput.name(of: $0).localizedCaseInsensitiveContains(name) }) else {
            throw ControlError("no MIDI destination called \(name); there are: " + destinations().joined(separator: ", "))
        }
        let size = 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        let list = buffer.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let packet = MIDIPacketListInit(list)
        _ = MIDIPacketListAdd(list, size, packet, 0, bytes.count, bytes)
        guard MIDISend(port, dest, list) == noErr else { throw ControlError("Core MIDI would not send") }
        // Core MIDI sends from its own thread; give it a moment before the client goes.
        Thread.sleep(forTimeInterval: 0.2)
    }
}
#endif
