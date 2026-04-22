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
            if line.isEmpty {
                // dispatch
                if !dataLines.isEmpty || currentEvent != nil {
                    let data = dataLines.joined(separator: "\n")
                    events.append(Event(event: currentEvent, data: data))
                }
                currentEvent = nil
                dataLines = []
            } else if line.hasPrefix("event:") {
                currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
            // ignore other fields (id:, retry:, comments)
        }
        return events
    }
}
