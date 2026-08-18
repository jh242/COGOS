import Foundation

/// Line-buffered SSE parser. Converts a byte stream into (event, data) pairs.
/// Events are separated by blank lines.
final class SSEParser {
    struct Event {
        var event: String?
        var data: String
    }

    private var buffer = ""
    private var currentEvent: String?
    private var dataLines: [String] = []

    /// Feed incoming bytes, returns any complete events parsed.
    func feed(_ chunk: Data) -> [Event] {
        guard let str = String(data: chunk, encoding: .utf8) else { return [] }
        buffer.append(str)
        var events: [Event] = []

        // Consume complete lines (ending in \n)
        while let nlIdx = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nlIdx]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            buffer.removeSubrange(...nlIdx)
            consume(line: line, into: &events)
        }
        return events
    }

    /// Flush a final event when the transport reaches EOF without the optional
    /// trailing blank line. Some proxies and test transports omit that last
    /// delimiter even though the event itself arrived in full.
    func finish() -> [Event] {
        var events: [Event] = []
        if !buffer.isEmpty {
            let line = buffer.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            buffer = ""
            consume(line: line, into: &events)
        }
        dispatch(into: &events)
        return events
    }

    private func consume(line: String, into events: inout [Event]) {
        if line.isEmpty {
            dispatch(into: &events)
        } else if line.hasPrefix("event:") {
            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        // Ignore other fields (id:, retry:, comments).
    }

    private func dispatch(into events: inout [Event]) {
        if !dataLines.isEmpty || currentEvent != nil {
            events.append(Event(event: currentEvent, data: dataLines.joined(separator: "\n")))
        }
        currentEvent = nil
        dataLines = []
    }
}
