import Foundation

@main struct BridgeStreamTests {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        let fixture: [String: Any] = ["type": "snapshot", "data": [
            "sessions": [], "activity": [], "pullRequests": [], "pipelines": [], "workItems": [],
            "connection": "connected", "errors": [], "hookStatus": "ready",
            "settings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings()))
        ]]
        let snapshot = try JSONSerialization.data(withJSONObject: fixture)
        let notice = Activity(id: "n1", title: "Ready", body: "Answer ✓", date: "2026-10-04T01:02:03Z", read: false, url: "", sessionID: "s1")
        let noticeData = try JSONEncoder().encode(notice)
        var payload = snapshot
        payload.append(10); payload.append(snapshot); payload.append(10)
        payload.append(Data("{\"type\":\"notice\",\"data\":".utf8)); payload.append(noticeData); payload.append(Data("}\n".utf8))
        payload.append(Data("invalid\n{\"type\":\"response\",\"id\":\"one\",\"result\":{\"ok\":true,\"items\":[1,null,\"✓\"]}}\n{\"type\":\"response\",\"id\":\"two\",\"error\":\"Denied\"}\n{\"type\":\"future-message\"}\n{\"type\":\"fatal\",\"message\":\"Stopped\"}".utf8))
        let stream = BridgeStream()
        // Split every UTF-8 codepoint and JSON line across separate pipe chunks.
        for byte in payload { stream.append(Data([byte])) }
        stream.finish()
        var events: [BridgeStreamEvent] = []
        for await event in stream.events { events.append(event) }
        check(events.count == 7, "Exactly one duplicate snapshot is suppressed; no notice/response is lost")
        if case .message(.snapshot(let value)) = events[0] { check(value.connection == "connected", "Snapshot decoded") }
        else { fatalError("Wrong snapshot order") }
        if case .message(.notice(let value)) = events[1] { check(value.body == "Answer ✓", "Split UTF-8 notice preserved") }
        else { fatalError("Wrong notice order") }
        if case .failure = events[2] { checks += 1 } else { fatalError("Malformed input must report an error without breaking the stream") }
        if case .message(.response(let id, let result, let error)) = events[3] {
            let object = try JSONSerialization.jsonObject(with: result) as! [String: Any]
            check(id == "one" && error == nil && object["ok"] as? Bool == true, "Response decoded after malformed line")
            check((object["items"] as? [Any])?.last as? String == "✓", "Nested JSON result preserved")
        } else { fatalError("Wrong response order") }
        if case .message(.response(let id, let result, let error)) = events[4] {
            check(id == "two" && error == "Denied" && String(decoding: result, as: UTF8.self) == "null", "Response error preserved")
        } else { fatalError("Error response lost") }
        if case .message(.ignored) = events[5] { checks += 1 } else { fatalError("Unknown message ignored") }
        if case .message(.fatal(let message)) = events[6] { check(message == "Stopped", "Final unterminated line drains on EOF") }
        else { fatalError("Final message lost") }
        check(displayDate("2026-10-04T01:02:03.000Z") == displayDate("2026-10-04T01:02:03Z"), "Date parser accepts fractional and whole seconds")
        check(displayDate("unknown") == "unknown", "Unrecognized date remains visible")
        print("Bridge stream: \(checks) checks passed")
    }
}
