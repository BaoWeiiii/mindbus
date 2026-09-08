import XCTest
@testable import MindBusCore

final class MarkdownSegmenterTests: XCTestCase {

    func testEmptyString() {
        XCTAssertEqual(MarkdownSegmenter.split(""), [])
    }

    func testPureProse() {
        let text = "Hello, this is plain text.\nWith two lines."
        XCTAssertEqual(
            MarkdownSegmenter.split(text),
            [.prose(text)]
        )
    }

    func testSingleFencedWithLanguage() {
        let text = """
        Before code:
        ```swift
        let x = 1
        ```
        After code.
        """
        XCTAssertEqual(
            MarkdownSegmenter.split(text),
            [
                .prose("Before code:"),
                .code(language: "swift", body: "let x = 1"),
                .prose("After code."),
            ]
        )
    }

    func testSingleFencedNoLanguage() {
        let text = """
        ```
        echo hi
        ```
        """
        XCTAssertEqual(
            MarkdownSegmenter.split(text),
            [.code(language: "", body: "echo hi")]
        )
    }

    func testMultipleFenced() {
        let text = """
        Intro
        ```ts
        const a = 1
        ```
        Middle
        ```py
        x = 2
        ```
        End
        """
        XCTAssertEqual(
            MarkdownSegmenter.split(text),
            [
                .prose("Intro"),
                .code(language: "ts", body: "const a = 1"),
                .prose("Middle"),
                .code(language: "py", body: "x = 2"),
                .prose("End"),
            ]
        )
    }

    func testUnclosedFenceTreatsRemainderAsCode() {
        let text = """
        Open fence below:
        ```bash
        echo "hi"
        echo "bye"
        """
        XCTAssertEqual(
            MarkdownSegmenter.split(text),
            [
                .prose("Open fence below:"),
                .code(language: "bash", body: "echo \"hi\"\necho \"bye\""),
            ]
        )
    }

    func testInlineCodeDoesNotSplit() {
        let text = "Use `git log` to see history."
        XCTAssertEqual(
            MarkdownSegmenter.split(text),
            [.prose(text)]
        )
    }

    func testFenceWithExtraInfoString() {
        let text = """
        ```swift {.numberLines}
        let x = 1
        ```
        """
        XCTAssertEqual(
            MarkdownSegmenter.split(text),
            [.code(language: "swift", body: "let x = 1")]
        )
    }

    func testEmptyCodeBlock() {
        let text = """
        ```ts
        ```
        """
        XCTAssertEqual(
            MarkdownSegmenter.split(text),
            [.code(language: "ts", body: "")]
        )
    }

    func testFenceAtStartAndEnd() {
        let text = "```\ncode\n```"
        XCTAssertEqual(
            MarkdownSegmenter.split(text),
            [.code(language: "", body: "code")]
        )
    }

    func testTwoFencesWithBlankProseBetween() {
        let text = "```ts\nx\n```\n\n```py\ny\n```"
        XCTAssertEqual(
            MarkdownSegmenter.split(text),
            [
                .code(language: "ts", body: "x"),
                .code(language: "py", body: "y"),
            ]
        )
    }
}
