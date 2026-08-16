import Foundation

public enum ImageSource: Equatable, Hashable {
    case base64(String)
    case url(String)
    case unknown
}

public enum ContentBlock: Equatable, Hashable {
    case text(String)
    case code(language: String, text: String)
    case toolUse(name: String, input: String)
    case toolResult(text: String)
    case thinking(String)
    case image(mediaType: String, source: ImageSource)

    public var plainText: String {
        switch self {
        case .text(let t): return t
        case .code(_, let t): return t
        case .toolUse(let n, let i): return "[tool: \(n)] \(i)"
        case .toolResult(let t): return t
        case .thinking(let t): return "[thinking] \(t)"
        case .image(let m, _): return "[image: \(m)]"
        }
    }
}
