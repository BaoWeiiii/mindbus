import Foundation

public enum MarkdownSegment: Equatable {
    case prose(String)
    case code(language: String, body: String)
}

public enum MarkdownSegmenter {

    public static func split(_ text: String) -> [MarkdownSegment] {
        if text.isEmpty { return [] }

        var segments: [MarkdownSegment] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var inFence = false
        var fenceLang = ""

        let lines = text.components(separatedBy: "\n")

        for line in lines {
            if inFence {
                if isFenceClose(line) {
                    segments.append(.code(language: fenceLang, body: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inFence = false
                    fenceLang = ""
                } else {
                    codeLines.append(line)
                }
            } else {
                if let lang = parseFenceOpen(line) {
                    flushProse(&segments, lines: &proseLines)
                    inFence = true
                    fenceLang = lang
                } else {
                    proseLines.append(line)
                }
            }
        }

        if inFence {
            segments.append(.code(language: fenceLang, body: codeLines.joined(separator: "\n")))
        } else {
            flushProse(&segments, lines: &proseLines)
        }

        return segments
    }

    private static func flushProse(_ segments: inout [MarkdownSegment], lines: inout [String]) {
        guard !lines.isEmpty else { return }
        let prose = lines.joined(separator: "\n")
        if !prose.isEmpty {
            segments.append(.prose(prose))
        }
        lines.removeAll()
    }

    private static func parseFenceOpen(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let info = trimmed.dropFirst(3)
        let lang = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return lang
    }

    private static func isFenceClose(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "```"
    }
}
