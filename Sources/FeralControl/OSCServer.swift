#if canImport(Network)
import Foundation
import Network

/// The engine's OSC port: UDP, as QLab's Network cues, consoles and Max send it. It reads packets from
/// anyone, hands each message on, and sends messages back to senders and subscribers. Every callback
/// runs on `queue`.
public final class OSCServer {
    /// Where a message came from, or where to send one.
    public struct Peer: Hashable, CustomStringConvertible {
        public var host: NWEndpoint.Host
        public var port: Int

        public init(host: NWEndpoint.Host, port: Int) {
            self.host = host; self.port = port
        }

        public var description: String { "\(host):\(port)" }
    }

    /// Senders' connections kept at once; the oldest is dropped beyond this.
    static let maxPeers = 128

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var incoming: [Peer: NWConnection] = [:]
    private var incomingOrder: [Peer] = []
    private var outgoing: [Peer: NWConnection] = [:]

    /// A message arrived from a peer.
    public var onMessage: ((OSCMessage, Peer) -> Void)?
    /// A packet could not be read.
    public var onBadPacket: ((String, Peer) -> Void)?
    public var onLog: ((String) -> Void)?
    public private(set) var port: Int?
    public var onReady: ((Int) -> Void)?

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Listens on `address` ("0.0.0.0" for any network, "127.0.0.1" for this Mac only) and `port`.
    public func start(address: String, port: Int) throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let nwPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw ControlError("bad port \(port)")
        }
        let listener: NWListener
        switch address {
        case "0.0.0.0", "any", "*":
            listener = try NWListener(using: params, on: nwPort)
        case "127.0.0.1", "localhost", "::1":
            params.requiredInterfaceType = .loopback
            listener = try NWListener(using: params, on: nwPort)
        default:
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: nwPort)
            listener = try NWListener(using: params)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let p = Int(listener.port?.rawValue ?? 0)
                self.port = p
                self.onLog?("osc: listening on \(address) UDP port \(p)")
                self.onReady?(p)
            case .failed(let error):
                self.onLog?("osc: the listener failed (\(error)); retrying in 2 s")
                listener.cancel()
                self.queue.asyncAfter(deadline: .now() + 2) { try? self.start(address: address, port: port) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for c in incoming.values { c.cancel() }
        for c in outgoing.values { c.cancel() }
        incoming = [:]
        incomingOrder = []
        outgoing = [:]
    }

    /// Sends messages to a peer, one packet each.
    public func send(_ messages: [OSCMessage], to peer: Peer) {
        guard !messages.isEmpty else { return }
        let c: NWConnection
        if let existing = outgoing[peer] {
            c = existing
        } else {
            guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: peer.port)) else { return }
            c = NWConnection(host: peer.host, port: p, using: .udp)
            c.stateUpdateHandler = { [weak self, weak c] state in
                guard let self, let c else { return }
                if case .failed = state { c.cancel(); if self.outgoing[peer] === c { self.outgoing[peer] = nil } }
            }
            c.start(queue: queue)
            outgoing[peer] = c
        }
        for m in messages { c.send(content: OSC.encode(m), completion: .contentProcessed { _ in }) }
    }

    /// Stops sending to a peer.
    public func forget(_ peer: Peer) {
        outgoing.removeValue(forKey: peer)?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, let port) = connection.endpoint else { connection.cancel(); return }
        let peer = Peer(host: host, port: Int(port.rawValue))
        incoming.removeValue(forKey: peer)?.cancel()
        incomingOrder.removeAll { $0 == peer }
        incoming[peer] = connection
        incomingOrder.append(peer)
        if incomingOrder.count > OSCServer.maxPeers {
            let oldest = incomingOrder.removeFirst()
            incoming.removeValue(forKey: oldest)?.cancel()
        }
        connection.start(queue: queue)
        receive(peer, connection)
    }

    private func receive(_ peer: Peer, _ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.incoming[peer] === connection else { return }
            if let data, !data.isEmpty {
                do {
                    for m in try OSC.messages(in: data) { self.onMessage?(m, peer) }
                } catch {
                    self.onBadPacket?("\(error)", peer)
                }
            }
            if error != nil {
                connection.cancel()
                self.incoming[peer] = nil
                self.incomingOrder.removeAll { $0 == peer }
            } else {
                self.receive(peer, connection)
            }
        }
    }
}
#endif
