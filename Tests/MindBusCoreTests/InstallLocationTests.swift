import XCTest
@testable import MindBusCore

/// App 跑在哪里决定了「把自己的路径写进别处」是否安全：
/// 直接在 DMG 里双击启动会被 Gatekeeper 做 App Translocation（跑在
/// `/private/var/folders/…/AppTranslocation/<随机>/d/MindBus.app`），或者干脆跑在
/// `/Volumes/MindBus/…`——这些路径一弹出镜像就失效。MCP 接入写进 `~/.claude.json` 的
/// `mindbus-mcp` 路径、开机自启注册、Sparkle 更新，全都依赖一个稳定位置。
final class InstallLocationTests: XCTestCase {

    func testApplicationsFolderIsInstalled() {
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Applications/MindBus.app"), .installed)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Users/dev/Applications/MindBus.app"), .installed)
        XCTAssertFalse(InstallLocation.isTransient(bundlePath: "/Applications/MindBus.app"))
    }

    func testTranslocatedPathIsTransient() {
        let p = "/private/var/folders/zz/abc123/T/AppTranslocation/1F2E3D4C-0000-4000-8000-000000000000/d/MindBus.app"
        XCTAssertEqual(InstallLocation.classify(bundlePath: p), .translocated)
        XCTAssertTrue(InstallLocation.isTransient(bundlePath: p))
    }

    func testMountedVolumeIsTransient() {
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Volumes/MindBus/MindBus.app"), .volume)
        XCTAssertTrue(InstallLocation.isTransient(bundlePath: "/Volumes/MindBus/MindBus.app"))
    }

    /// `swift build` 裸跑不是 .app，属于开发场景，不算临时位置
    func testBareExecutableIsNotTransient() {
        let p = "/Users/dev/mindbus/.build/arm64-apple-macosx/debug"
        XCTAssertEqual(InstallLocation.classify(bundlePath: p), .bare)
        XCTAssertFalse(InstallLocation.isTransient(bundlePath: p))
    }

    /// 下载目录里的 .app 若没被 translocation 就是普通位置——不误报
    func testDownloadsFolderIsNotFlaggedByItself() {
        XCTAssertFalse(InstallLocation.isTransient(bundlePath: "/Users/dev/Downloads/MindBus.app"))
    }
}
