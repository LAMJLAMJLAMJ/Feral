#if canImport(Network)
import Foundation
import Network

/// The engine's end of the control link: a TCP listener that reads requests from any number of
/// clients and sends events to one or all of them. Every callback runs on `queue`.
public final class ControlServer {
    public typealias ClientID = Int

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var clients: [ClientID: NWConnection] = [:]
    private var buffers: [ClientID: Wire.LineBuffer] = [:]
    private var nextID = 1

    /// A client connected; send it the state.
    public var onConnect: ((ClientID) -> Void)?
    public var onDisconnect: ((ClientID) -> Void)?
    public var onRequest: ((ClientID, Request) -> Void)?
    public var onLog: ((String) -> Void)?
    /// The port it listens on, once it is listening (useful when started on port 0).
    public private(set) var port: Int?
    public var onReady: ((Int) -> Void)?

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    public var clientCount: Int { clients.count }

    /// Listens on `address` ("127.0.0.1" for this Mac only, "0.0.0.0" for any network) and `port`
    /// (0 picks a free one).
    public func start(address: String, port: Int) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
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
                self.onLog?("control: listening on \(address) port \(p)")
                self.onReady?(p)
            case .failed(let error):
                self.onLog?("control: the listener failed (\(error)); retrying in 2 s")
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
        for c in clients.values { c.cancel() }
        clients = [:]
        buffers = [:]
    }

    public func send(_ event: Event, to client: ClientID) {
        guard let c = clients[client], let data = try? Wire.encode(event) else { return }
        c.send(content: data, completion: .contentProcessed { _ in })
    }

    public func broadcast(_ event: Event) {
        guard !clients.isEmpty, let data = try? Wire.encode(event) else { return }
        for c in clients.values { c.send(content: data, completion: .contentProcessed { _ in }) }
    }

    private func accept(_ connection: NWConnection) {
        let id = nextID
        nextID += 1
        clients[id] = connection
        buffers[id] = Wire.LineBuffer()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onConnect?(id)
            case .failed, .cancelled:
                self.drop(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(id, connection)
    }

    private func receive(_ id: ClientID, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, self.clients[id] != nil else { return }
            if let data, !data.isEmpty {
                do {
                    let lines = try self.buffers[id]?.append(data) ?? []
                    for line in lines {
                        do {
                            self.onRequest?(id, try Wire.decode(Request.self, from: line))
                        } catch {
                            self.send(.error(message: "could not read the request: \(error)"), to: id)
                        }
                    }
                } catch {
                    self.onLog?("control: client \(id): \(error); disconnecting it")
                    connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                self.drop(id)
            } else {
                self.receive(id, connection)
            }
        }
    }

    private func drop(_ id: ClientID) {
        guard clients.removeValue(forKey: id) != nil else { return }
        buffers[id] = nil
        onDisconnect?(id)
    }
}

/// The app's and feral-cli's end of the control link. It connects, and reconnects every second
/// whenever the engine is not there. Every callback runs on `queue`.
public final class ControlClient {
    public let host: String
    public let port: Int
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var buffer = Wire.LineBuffer()
    private var running = false
    private let name: String

    public var onEvent: ((Event) -> Void)?
    /// True when connected, false when the link drops.
    public var onConnected: ((Bool) -> Void)?
    public private(set) var isConnected = false

    public init(host: String = "127.0.0.1", port: Int = defaultControlPort, name: String, queue: DispatchQueue) {
        self.host = host; self.port = port; self.name = name; self.queue = queue
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            connect()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            connection?.cancel()
            connection = nil
            setConnected(false)
        }
    }

    public func send(_ request: Request) {
        queue.async { [self] in
            guard let connection, isConnected, let data = try? Wire.encode(request) else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func connect() {
        guard running, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        connection = c
        buffer = Wire.LineBuffer()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.connection else { return }
            switch state {
            case .ready:
                self.setConnected(true)
                if let data = try? Wire.encode(Request.hello(client: self.name)) {
                    c.send(content: data, completion: .contentProcessed { _ in })
                }
                self.receive(c)
            case .waiting, .failed:
                self.retry(c)
            case .cancelled:
                self.setConnected(false)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func retry(_ c: NWConnection) {
        c.cancel()
        guard c === connection else { return }
        connection = nil
        setConnected(false)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.running, self.connection == nil else { return }
            self.connect()
        }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, c === self.connection else { return }
            if let data, !data.isEmpty {
                guard let lines = try? self.buffer.append(data) else { self.retry(c); return }
                for line in lines {
                    if let event = try? Wire.decode(Event.self, from: line) { self.onEvent?(event) }
                }
            }
            if isComplete || error != nil { self.retry(c) } else { self.receive(c) }
        }
    }

    private func setConnected(_ value: Bool) {
        guard value != isConnected else { return }
        isConnected = value
        onConnected?(value)
    }
}

public struct ControlError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
#endif
