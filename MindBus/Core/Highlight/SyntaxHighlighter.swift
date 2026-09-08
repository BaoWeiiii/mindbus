import Foundation

public enum HighlightTokenKind: Equatable {
    case plain
    case keyword
    case string
    case comment
}

public struct HighlightToken: Equatable {
    public let kind: HighlightTokenKind
    public let text: String

    public init(kind: HighlightTokenKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum SyntaxHighlighter {

    public static func highlight(language: String, code: String) -> [HighlightToken] {
        guard !code.isEmpty else { return [] }
        guard let rules = languageRules(for: language) else {
            return [HighlightToken(kind: .plain, text: code)]
        }

        let scalars = Array(code)
        var tokens: [HighlightToken] = []
        var plainBuffer = ""
        var i = 0

        func flushPlain() {
            if !plainBuffer.isEmpty {
                tokens.append(HighlightToken(kind: .plain, text: plainBuffer))
                plainBuffer = ""
            }
        }

        func emit(_ kind: HighlightTokenKind, _ text: String) {
            flushPlain()
            tokens.append(HighlightToken(kind: kind, text: text))
        }

        while i < scalars.count {
            let c = scalars[i]

            if let prefix = rules.lineComments.first(where: { matchesPrefix($0, scalars, at: i) }) {
                let start = i
                while i < scalars.count && scalars[i] != "\n" { i += 1 }
                emit(.comment, String(scalars[start..<i]))
                _ = prefix
                continue
            }

            if let bc = rules.blockComments.first(where: { matchesPrefix($0.open, scalars, at: i) }) {
                let start = i
                i += bc.open.count
                while i < scalars.count && !matchesPrefix(bc.close, scalars, at: i) {
                    i += 1
                }
                if i < scalars.count {
                    i += bc.close.count
                }
                emit(.comment, String(scalars[start..<i]))
                continue
            }

            if rules.stringDelimiters.contains(c) {
                let delim = c
                let start = i
                i += 1
                while i < scalars.count {
                    let ch = scalars[i]
                    if ch == "\\" && i + 1 < scalars.count {
                        i += 2
                        continue
                    }
                    if ch == delim {
                        i += 1
                        break
                    }
                    if ch == "\n" {
                        break
                    }
                    i += 1
                }
                emit(.string, String(scalars[start..<i]))
                continue
            }

            if c.isLetter || c == "_" {
                let start = i
                while i < scalars.count {
                    let ch = scalars[i]
                    if ch.isLetter || ch.isNumber || ch == "_" {
                        i += 1
                    } else {
                        break
                    }
                }
                let word = String(scalars[start..<i])
                let lookup = rules.caseInsensitiveKeywords ? word.lowercased() : word
                if rules.keywords.contains(lookup) {
                    emit(.keyword, word)
                } else {
                    plainBuffer += word
                }
                continue
            }

            plainBuffer.append(c)
            i += 1
        }

        flushPlain()
        return tokens
    }

    public static func supports(language: String) -> Bool {
        languageRules(for: language) != nil
    }

    // MARK: - private

    private static func matchesPrefix(_ prefix: String, _ scalars: [Character], at index: Int) -> Bool {
        let prefixChars = Array(prefix)
        guard index + prefixChars.count <= scalars.count else { return false }
        for j in 0..<prefixChars.count where scalars[index + j] != prefixChars[j] {
            return false
        }
        return true
    }

    private struct LanguageRules {
        let keywords: Set<String>
        let lineComments: [String]
        let blockComments: [(open: String, close: String)]
        let stringDelimiters: Set<Character>
        let caseInsensitiveKeywords: Bool
    }

    private static func languageRules(for language: String) -> LanguageRules? {
        switch language.lowercased() {
        case "swift":
            return LanguageRules(
                keywords: [
                    "let", "var", "func", "class", "struct", "enum", "protocol", "extension",
                    "if", "else", "guard", "switch", "case", "default", "for", "while", "in",
                    "return", "import", "public", "private", "internal", "fileprivate", "open",
                    "static", "final", "init", "self", "Self", "true", "false", "nil",
                    "throw", "throws", "rethrows", "try", "catch", "do", "as", "is", "where",
                    "associatedtype", "typealias", "lazy", "weak", "unowned", "mutating",
                    "nonmutating", "inout", "async", "await", "actor", "deinit", "subscript",
                    "operator", "precedencegroup", "Any", "Type",
                ],
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                stringDelimiters: ["\""],
                caseInsensitiveKeywords: false
            )

        case "ts", "tsx", "js", "jsx", "javascript", "typescript", "mjs", "cjs":
            return LanguageRules(
                keywords: [
                    "const", "let", "var", "function", "return", "if", "else", "for", "while",
                    "do", "break", "continue", "import", "export", "from", "as", "default",
                    "async", "await", "class", "extends", "implements", "interface", "type",
                    "enum", "new", "this", "super", "null", "undefined", "true", "false",
                    "void", "typeof", "instanceof", "switch", "case", "throw", "try", "catch",
                    "finally", "yield", "static", "public", "private", "protected", "readonly",
                    "abstract", "in", "of", "delete",
                ],
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                stringDelimiters: ["\"", "'", "`"],
                caseInsensitiveKeywords: false
            )

        case "py", "python":
            return LanguageRules(
                keywords: [
                    "def", "class", "if", "elif", "else", "for", "while", "in", "not", "and",
                    "or", "return", "yield", "import", "from", "as", "with", "try", "except",
                    "finally", "raise", "pass", "break", "continue", "lambda", "global",
                    "nonlocal", "True", "False", "None", "is", "async", "await", "self", "cls",
                ],
                lineComments: ["#"],
                blockComments: [],
                stringDelimiters: ["\"", "'"],
                caseInsensitiveKeywords: false
            )

        case "sh", "bash", "zsh", "shell":
            return LanguageRules(
                keywords: [
                    "if", "then", "elif", "else", "fi", "for", "while", "do", "done", "case",
                    "esac", "in", "function", "return", "echo", "export", "local", "readonly",
                    "set", "unset", "source", "exit", "true", "false",
                ],
                lineComments: ["#"],
                blockComments: [],
                stringDelimiters: ["\"", "'"],
                caseInsensitiveKeywords: false
            )

        case "sql":
            return LanguageRules(
                keywords: [
                    "select", "from", "where", "insert", "into", "values", "update", "set",
                    "delete", "create", "table", "drop", "alter", "add", "column", "index",
                    "primary", "key", "foreign", "references", "join", "left", "right",
                    "inner", "outer", "on", "as", "and", "or", "not", "null", "is", "in",
                    "between", "like", "exists", "group", "by", "order", "asc", "desc",
                    "having", "limit", "offset", "distinct", "union", "all", "true", "false",
                    "case", "when", "then", "else", "end",
                ],
                lineComments: ["--"],
                blockComments: [("/*", "*/")],
                stringDelimiters: ["'", "\""],
                caseInsensitiveKeywords: true
            )

        case "json":
            return LanguageRules(
                keywords: ["true", "false", "null"],
                lineComments: [],
                blockComments: [],
                stringDelimiters: ["\""],
                caseInsensitiveKeywords: false
            )

        case "go", "golang":
            return LanguageRules(
                keywords: [
                    "package", "import", "func", "var", "const", "type", "struct", "interface",
                    "if", "else", "for", "range", "return", "break", "continue", "switch",
                    "case", "default", "go", "defer", "chan", "select", "map", "true", "false",
                    "nil",
                ],
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                stringDelimiters: ["\"", "`"],
                caseInsensitiveKeywords: false
            )

        case "rust", "rs":
            return LanguageRules(
                keywords: [
                    "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl",
                    "for", "while", "loop", "if", "else", "match", "return", "break",
                    "continue", "use", "mod", "pub", "crate", "self", "Self", "super", "as",
                    "in", "ref", "where", "true", "false", "unsafe", "async", "await", "move",
                    "dyn",
                ],
                lineComments: ["//"],
                blockComments: [("/*", "*/")],
                stringDelimiters: ["\""],
                caseInsensitiveKeywords: false
            )

        default:
            return nil
        }
    }
}
