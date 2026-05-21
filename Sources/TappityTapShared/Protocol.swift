import Foundation

// JSON-line wire protocol between the root helper and the user-context app.
// Single Unix socket at SocketPath.default. Helper is the server, app is the
// client. One connected client at a time — newer connections displace older.

public enum SocketPath {
    public static let `default` = "/tmp/tappitytap.sock"
}

public struct ServerMessage: Codable {
    public let type: String         // "hello" | "tap"
    public let sampleHz: Int?       // hello
    public let intensity: Double?   // tap
    public let timestamp: Double?   // tap (seconds since helper start)

    public static func hello(sampleHz: Int) -> ServerMessage {
        return ServerMessage(type: "hello", sampleHz: sampleHz, intensity: nil, timestamp: nil)
    }

    public static func tap(intensity: Double, timestamp: Double) -> ServerMessage {
        return ServerMessage(type: "tap", sampleHz: nil, intensity: intensity, timestamp: timestamp)
    }

    public init(type: String, sampleHz: Int?, intensity: Double?, timestamp: Double?) {
        self.type = type
        self.sampleHz = sampleHz
        self.intensity = intensity
        self.timestamp = timestamp
    }
}

public struct ClientMessage: Codable {
    public let type: String         // "setParams"
    public let deltaG: Double?
    public let minPeakG: Double?
    public let blackoutMs: Int?
    public let enabled: Bool?

    public static func setParams(deltaG: Double, minPeakG: Double, blackoutMs: Int, enabled: Bool) -> ClientMessage {
        return ClientMessage(type: "setParams", deltaG: deltaG, minPeakG: minPeakG, blackoutMs: blackoutMs, enabled: enabled)
    }

    public init(type: String, deltaG: Double?, minPeakG: Double?, blackoutMs: Int?, enabled: Bool?) {
        self.type = type
        self.deltaG = deltaG
        self.minPeakG = minPeakG
        self.blackoutMs = blackoutMs
        self.enabled = enabled
    }
}

// Helpers — encode to a single-line JSON string with trailing newline.
public func encodeLine<T: Encodable>(_ value: T) -> Data {
    var data = try! JSONEncoder().encode(value)
    data.append(0x0A)
    return data
}

public func decodeLine<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
    return try JSONDecoder().decode(type, from: data)
}
