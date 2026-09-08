import XCTest
@testable import MindBusCore

/// 来源开关：默认全开；关掉的来源持久化为 rawValue 数组；未知值忽略；写入发通知。
final class SourcePreferencesTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "ai.mindbus.tests.sourceprefs.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        SourcePreferences.defaults = suite
    }

    override func tearDown() {
        SourcePreferences.defaults = .standard
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultAllEnabled() {
        XCTAssertTrue(SourcePreferences.disabledSources().isEmpty)
        for s in ConversationSource.allCases { XCTAssertTrue(SourcePreferences.isEnabled(s)) }
    }

    func testDisableAndReenableRoundTrip() {
        SourcePreferences.setEnabled(false, for: .codex)
        XCTAssertFalse(SourcePreferences.isEnabled(.codex))
        XCTAssertTrue(SourcePreferences.isEnabled(.claudeCode))
        XCTAssertEqual(suite.stringArray(forKey: SourcePreferences.defaultsKey), ["codex"])

        SourcePreferences.setEnabled(true, for: .codex)
        XCTAssertTrue(SourcePreferences.isEnabled(.codex))
        XCTAssertNil(suite.object(forKey: SourcePreferences.defaultsKey), "全开时不留空数组")
    }

    func testUnknownRawValuesIgnored() {
        suite.set(["codex", "bogus"], forKey: SourcePreferences.defaultsKey)
        XCTAssertEqual(SourcePreferences.disabledSources(), [.codex])
    }

    func testChangeNotificationPosted() {
        let exp = expectation(forNotification: SourcePreferences.changed, object: nil)
        SourcePreferences.setDisabled([.claudeAgent])
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(SourcePreferences.disabledSources(), [.claudeAgent])
    }
}
