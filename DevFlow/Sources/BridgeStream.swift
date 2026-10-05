import Foundation

/// Decode complete wire messages once, away from the UI executor.
enum BridgeMessage: Decodable, Sendable {
    case snapshot(Snapshot)
    case notice(Activity)
    case response(id: String, result: Data, error: String?)
    case fatal(String)
    case ignored

    private enum Keys: String, CodingKey { case type, data, id, result, error, message }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "snapshot": self = .snapshot(try values.decode(Snapshot.self, forKey: .data))
        case "notice": self = .notice(try values.decode(Activity.self, forKey: .data))
        case "fatal": self = .fatal(try values.decodeIfPresent(String.self, forKey: .message) ?? "Local bridge failed.")
        case "response":
            let result = try values.decodeIfPresent(JSONValue.self, forKey: .result) ?? .null
            self = .response(id: try values.decode(String.self, forKey: .id),
                             result: try JSONEncoder().encode(result),
                             error: try values.decodeIfPresent(String.self, forKey: .error))
        default: self = .ignored
        }
    }
}

private enum JSONValue: Codable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
}

enum BridgeStreamEvent: Sendable {
    case message(BridgeMessage)
    case failure(String)
}

/// All mutable state is confined to `queue`; the AsyncStream delivers FIFO to
/// one UI consumer. Neither pipe chunk boundaries nor UTF-8 boundaries matter.
final class BridgeStream: @unchecked Sendable {
    let events: AsyncStream<BridgeStreamEvent>
    private let continuation: AsyncStream<BridgeStreamEvent>.Continuation
    private let queue = DispatchQueue(label: "dev.devflow.bridge.decode", qos: .userInitiated)
    private var line = Data()
    private var lastSnapshot: Snapshot?
    private let decoder = JSONDecoder()

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func append(_ data: Data) {
        queue.async { [self] in
            var start = data.startIndex
            while let newline = data[start...].firstIndex(of: 10) {
                line.append(contentsOf: data[start..<newline])
                decodeLine()
                line.removeAll(keepingCapacity: true)
                start = data.index(after: newline)
            }
            line.append(contentsOf: data[start...])
        }
    }

    func finish() {
        queue.async { [self] in
            if !line.isEmpty { decodeLine(); line.removeAll() }
            continuation.finish()
        }
    }

    private func decodeLine() {
        guard !line.isEmpty else { return }
        do {
            let message = try decoder.decode(BridgeMessage.self, from: line)
            if case .snapshot(let snapshot) = message {
                guard snapshot != lastSnapshot else { return }
                lastSnapshot = snapshot
            }
            continuation.yield(.message(message))
        } catch {
            continuation.yield(.failure("Could not read local state: \(error.localizedDescription)"))
        }
    }
}
