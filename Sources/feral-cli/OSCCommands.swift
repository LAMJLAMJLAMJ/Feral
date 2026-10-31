import FeralControl
import FeralScene
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// feral-cli osc and osc-watch: OSC to and from the running engine over UDP, as QLab, a console or Max
// would send it, for testing from Terminal. Plain sockets, so it builds everywhere.

/// The engine's OSC port: --osc-port, else engine.json's oscPort, else 9200.
func engineOSCPort() -> Int {
    if let oscPort { return oscPort }
    return (try? EngineConfig.load(from: configURL))?.oscPort ?? EngineConfig().oscPort
}

/// A UDP socket that sends to the engine and reads what comes back.
final class OSCSocket {
    private let fd: Int32
    private var engine = sockaddr_in()

    init(host: String, port: Int) {
        #if os(Linux)
        fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        guard fd >= 0 else { fail("cannot open a UDP socket") }
        guard (1...65_535).contains(port) else { fail("the engine's OSC port is off (oscPort 0 in engine.json)") }
        engine.sin_family = sa_family_t(AF_INET)
        engine.sin_port = in_port_t(UInt16(port)).bigEndian
        #if !os(Linux)
        engine.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let address = host == "localhost" ? "127.0.0.1" : host
        guard inet_pton(AF_INET, address, &engine.sin_addr) == 1 else { fail("--host must be an IPv4 address such as 127.0.0.1") }
    }

    deinit { close(fd) }

    func send(_ packet: Data) {
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &engine) { a in
                a.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { fail("could not send to the engine: \(String(cString: strerror(errno)))") }
    }

    /// The messages in the next packet, or none if nothing came within `timeout` seconds.
    func receive(timeout: Double) -> [OSCMessage]? {
        var tv = timeval()
        tv.tv_sec = .init(Int(timeout))
        tv.tv_usec = .init(Int((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return nil }
        return (try? OSC.messages(in: Data(buffer[0..<n]))) ?? []
    }
}

/// An argument as typed: a whole number is an int, a number with a point a float, anything else text.
func oscArgument(_ text: String) -> OSCValue {
    if let i = Int32(text) { return .int(i) }
    if let f = Float(text), f.isFinite { return .float(f) }
    return .string(text)
}

func runOSCCommand(_ command: String, _ args: [String]) {
    let socket = OSCSocket(host: host, port: engineOSCPort())
    switch command {
    case "osc":
        guard let address = args.first, address.hasPrefix("/") else {
            fail("osc needs an address and its arguments: feral-cli osc /feral/source/1/xyz 2 6 1.6")
        }
        let m = OSCMessage(address, args.dropFirst().map(oscArgument))
        socket.send(OSC.encode(m))
        print("sent \(m.description) to \(host) port \(engineOSCPort())")
        // Print anything the engine answers (/feral/pong, /feral/error) for a moment.
        while let replies = socket.receive(timeout: 0.3) {
            for r in replies { print("  \(r.description)") }
        }

    case "osc-watch":
        let subscribe = OSCMessage("/feral/subscribe", adm ? [.string("adm")] : [])
        socket.send(OSC.encode(subscribe))
        print("watching \(host) port \(engineOSCPort())" + (adm ? " in ADM-OSC" : "") + "; Ctrl-C to stop")
        var lastSubscribe = Date()
        let until = seconds.map { Date() + $0 }
        while until.map({ Date() < $0 }) ?? true {
            if let messages = socket.receive(timeout: 0.5) {
                for m in messages { print(m.description) }
                fflush(stdout)
            }
            // Subscribe again now and then, in case the engine restarted.
            if Date().timeIntervalSince(lastSubscribe) > 10 {
                socket.send(OSC.encode(subscribe))
                lastSubscribe = Date()
            }
        }
        socket.send(OSC.encode(OSCMessage("/feral/unsubscribe")))

    default:
        fail("unknown OSC command \(command)")
    }
}
