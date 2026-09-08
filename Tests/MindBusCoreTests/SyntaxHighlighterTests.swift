import XCTest
@testable import MindBusCore

final class SyntaxHighlighterTests: XCTestCase {

    // MARK: - basic

    func testEmptyCode() {
        XCTAssertEqual(SyntaxHighlighter.highlight(language: "swift", code: ""), [])
    }

    func testUnknownLanguageReturnsPlain() {
        let code = "let x = 1"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "ruby", code: code),
            [HighlightToken(kind: .plain, text: code)]
        )
    }

    func testEmptyLanguageReturnsPlain() {
        let code = "echo hi"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "", code: code),
            [HighlightToken(kind: .plain, text: code)]
        )
    }

    // MARK: - swift

    func testSwiftKeywordStringComment() {
        let code = "let x = \"hello\" // comment"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "swift", code: code),
            [
                HighlightToken(kind: .keyword, text: "let"),
                HighlightToken(kind: .plain, text: " x = "),
                HighlightToken(kind: .string, text: "\"hello\""),
                HighlightToken(kind: .plain, text: " "),
                HighlightToken(kind: .comment, text: "// comment"),
            ]
        )
    }

    func testSwiftBlockComment() {
        let code = "let x = 1 /* note */ + 2"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "swift", code: code),
            [
                HighlightToken(kind: .keyword, text: "let"),
                HighlightToken(kind: .plain, text: " x = 1 "),
                HighlightToken(kind: .comment, text: "/* note */"),
                HighlightToken(kind: .plain, text: " + 2"),
            ]
        )
    }

    func testKeywordPrefixDoesNotMatch() {
        // "letter" must not be highlighted as "let"
        let code = "letter"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "swift", code: code),
            [HighlightToken(kind: .plain, text: "letter")]
        )
    }

    // MARK: - typescript / javascript

    func testTSConstAndTemplateString() {
        let code = "const x = `hi`"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "ts", code: code),
            [
                HighlightToken(kind: .keyword, text: "const"),
                HighlightToken(kind: .plain, text: " x = "),
                HighlightToken(kind: .string, text: "`hi`"),
            ]
        )
    }

    func testJSSingleQuote() {
        let code = "var name = 'Alice'"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "js", code: code),
            [
                HighlightToken(kind: .keyword, text: "var"),
                HighlightToken(kind: .plain, text: " name = "),
                HighlightToken(kind: .string, text: "'Alice'"),
            ]
        )
    }

    // MARK: - python

    func testPyDefAndComment() {
        let code = "def foo(): # bar"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "py", code: code),
            [
                HighlightToken(kind: .keyword, text: "def"),
                HighlightToken(kind: .plain, text: " foo(): "),
                HighlightToken(kind: .comment, text: "# bar"),
            ]
        )
    }

    // MARK: - bash

    func testBashEchoString() {
        let code = "echo \"hi\" # tail"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "bash", code: code),
            [
                HighlightToken(kind: .keyword, text: "echo"),
                HighlightToken(kind: .plain, text: " "),
                HighlightToken(kind: .string, text: "\"hi\""),
                HighlightToken(kind: .plain, text: " "),
                HighlightToken(kind: .comment, text: "# tail"),
            ]
        )
    }

    // MARK: - sql

    func testSQLCaseInsensitiveKeywords() {
        let code = "SELECT * FROM users -- where"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "sql", code: code),
            [
                HighlightToken(kind: .keyword, text: "SELECT"),
                HighlightToken(kind: .plain, text: " * "),
                HighlightToken(kind: .keyword, text: "FROM"),
                HighlightToken(kind: .plain, text: " users "),
                HighlightToken(kind: .comment, text: "-- where"),
            ]
        )
    }

    // MARK: - json

    func testJSONLiterals() {
        let code = "{\"a\": true, \"b\": null}"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "json", code: code),
            [
                HighlightToken(kind: .plain, text: "{"),
                HighlightToken(kind: .string, text: "\"a\""),
                HighlightToken(kind: .plain, text: ": "),
                HighlightToken(kind: .keyword, text: "true"),
                HighlightToken(kind: .plain, text: ", "),
                HighlightToken(kind: .string, text: "\"b\""),
                HighlightToken(kind: .plain, text: ": "),
                HighlightToken(kind: .keyword, text: "null"),
                HighlightToken(kind: .plain, text: "}"),
            ]
        )
    }

    // MARK: - go

    func testGoBacktickString() {
        let code = "var s = `raw`"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "go", code: code),
            [
                HighlightToken(kind: .keyword, text: "var"),
                HighlightToken(kind: .plain, text: " s = "),
                HighlightToken(kind: .string, text: "`raw`"),
            ]
        )
    }

    // MARK: - escaping

    func testEscapedQuoteInString() {
        let code = "\"hello \\\"world\\\"\""
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "swift", code: code),
            [HighlightToken(kind: .string, text: "\"hello \\\"world\\\"\"")]
        )
    }

    func testUnterminatedStringStopsAtNewline() {
        let code = "\"oops\nlet x = 1"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "swift", code: code),
            [
                HighlightToken(kind: .string, text: "\"oops"),
                HighlightToken(kind: .plain, text: "\n"),
                HighlightToken(kind: .keyword, text: "let"),
                HighlightToken(kind: .plain, text: " x = 1"),
            ]
        )
    }

    // MARK: - multi-line

    func testMultiLineSwift() {
        let code = "let a = 1\nlet b = 2"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(language: "swift", code: code),
            [
                HighlightToken(kind: .keyword, text: "let"),
                HighlightToken(kind: .plain, text: " a = 1\n"),
                HighlightToken(kind: .keyword, text: "let"),
                HighlightToken(kind: .plain, text: " b = 2"),
            ]
        )
    }
}
