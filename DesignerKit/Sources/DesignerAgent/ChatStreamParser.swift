import Foundation

/// Parses the Claude Code CLI's `--output-format stream-json` line protocol
/// into the events the in-app chat panel renders (F6). Pure — the process
/// plumbing lives in the app layer.
public enum ChatStreamEvent: Equatable {
    case sessionStarted(id: String)
    case assistantText(String)
    /// The assistant invoked a tool (e.g. "mcp__designer__propose_board").
    case toolUse(name: String)
    case finished(success: Bool, summary: String?)
    /// Anything unrecognized is ignored, but surfaced for debugging.
    case ignored
}

public enum ChatStreamParser {
    /// Parses one JSONL line. Unknown or malformed lines return `.ignored` —
    /// the CLI adds event types over time and the chat must not break.
    public static func parse(_ line: Data) -> [ChatStreamEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return [.ignored] }

        switch type {
        case "system":
            if object["subtype"] as? String == "init", let id = object["session_id"] as? String {
                return [.sessionStarted(id: id)]
            }
            return [.ignored]

        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [.ignored] }
            var events: [ChatStreamEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        events.append(.assistantText(text))
                    }
                case "tool_use":
                    if let name = block["name"] as? String {
                        events.append(.toolUse(name: name))
                    }
                default:
                    break // thinking etc. — not rendered
                }
            }
            return events.isEmpty ? [.ignored] : events

        case "result":
            let isError = object["is_error"] as? Bool ?? false
            let summary = object["result"] as? String
            return [.finished(success: !isError, summary: summary)]

        default:
            return [.ignored]
        }
    }

    /// Splits accumulated pipe bytes into complete lines, returning the
    /// remainder (a partial trailing line) for the next read.
    public static func drainLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    /// A friendly label for a designer tool call, for the activity chip.
    public static func activityLabel(forTool name: String) -> String {
        switch name {
        case "mcp__designer__describe_board": return "Looking at the board"
        case "mcp__designer__get_board": return "Reading the board"
        case "mcp__designer__search_board": return "Searching the board"
        case "mcp__designer__propose_board": return "Proposing changes — review them above"
        default: return "Using \(name)"
        }
    }
}
