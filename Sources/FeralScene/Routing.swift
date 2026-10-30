import Foundation

/// One line of the fixed routing: a set of engine inputs to a set of engine outputs at a gain.
/// Channels count from 1 and are written as "5" or "1-128".
///
/// - Equal-sized sets pair up in order ("1-64" to "65-128" sends input 1 to output 65, and so on).
/// - One input to several outputs feeds them all (handy for testing every output from one source).
/// - Several inputs to one output sums them.
public struct Route: Codable, Equatable {
    public var inputs: String
    public var outputs: String
    public var gainDB: Double

    public init(inputs: String, outputs: String, gainDB: Double = 0) {
        self.inputs = inputs
        self.outputs = outputs
        self.gainDB = gainDB
    }

    enum CodingKeys: String, CodingKey { case inputs, outputs, gainDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Allow plain numbers as well as strings: "inputs": 3.
        func channels(_ key: CodingKeys) throws -> String {
            if let n = try? c.decode(Int.self, forKey: key) { return String(n) }
            return try c.decode(String.self, forKey: key)
        }
        inputs = try channels(.inputs)
        outputs = try channels(.outputs)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
    }
}

/// The fixed gain matrix the engine plays in milestone 1.
public struct Routing: Equatable {
    public static let maxChannels = 256

    public let inputs: Int
    public let outputs: Int
    /// Linear gains, outputs rows of inputs each: gains[out * inputs + in], from 0.
    public private(set) var gains: [Float]

    /// Builds the matrix. No routes means a passthrough: input n to output n.
    public init(routes: [Route], inputs: Int, outputs: Int) throws {
        self.inputs = inputs
        self.outputs = outputs
        gains = [Float](repeating: 0, count: inputs * outputs)
        if routes.isEmpty {
            for n in 0..<min(inputs, outputs) { gains[n * inputs + n] = 1 }
            return
        }
        for route in routes {
            let ins = try Routing.channels(route.inputs, limit: inputs, side: "input")
            let outs = try Routing.channels(route.outputs, limit: outputs, side: "output")
            let gain = route.gainDB <= -144 ? 0 : Float(pow(10, route.gainDB / 20))
            let pairs: [(Int, Int)]
            if ins.count == outs.count {
                pairs = Array(zip(ins, outs))
            } else if ins.count == 1 {
                pairs = outs.map { (ins[0], $0) }
            } else if outs.count == 1 {
                pairs = ins.map { ($0, outs[0]) }
            } else {
                throw ConfigError("route \(route.inputs) to \(route.outputs): give the same number of inputs and outputs, or one on either side")
            }
            // A later route to the same pair replaces the earlier one.
            for (i, o) in pairs { gains[(o - 1) * inputs + (i - 1)] = gain }
        }
    }

    /// Parses "5" or "1-128" into channel numbers from 1.
    static func channels(_ text: String, limit: Int, side: String) throws -> [Int] {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count), let first = Int(parts[0]), let last = Int(parts.last!), first <= last else {
            throw ConfigError("'\(text)' is not a channel or a range such as 1-128")
        }
        guard first >= 1, last <= limit else {
            throw ConfigError("\(side) '\(text)' is outside 1-\(limit)")
        }
        return Array(first...last)
    }

    /// The linear gain from input i to output o, both from 1.
    public func gain(input i: Int, output o: Int) -> Float { gains[(o - 1) * inputs + (i - 1)] }
}
