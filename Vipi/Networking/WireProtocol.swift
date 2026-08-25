import Foundation

struct ClientEnvelope<Payload: Encodable>: Encodable {
    let id: String
    let type: String
    let protocolVersion = 1
    let payload: Payload
}

struct ServerEnvelope: Decodable, Sendable {
    let id: String?
    let type: String
    let seq: Int?
    let payload: JSONValue?
}

indirect enum JSONValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try box.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .object(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .null: try box.encodeNil()
        }
    }
}

struct AuthenticatePayload: Encodable { let token: String; let lastSeq: Int? }
struct SessionCommandPayload: Encodable { let sessionID: String }
struct PromptPayload: Encodable {
    let sessionID: String
    let text: String
    let delivery: PromptDelivery
    let annotations: [ChatAnnotation]
}
struct RenamePayload: Encodable { let sessionID: String; let name: String }
