import XCTest
@testable import MindBusCore

/// issue #3：Releases DMG 在用户机器上打开即崩。
///
/// SwiftPM 生成的 `Bundle.module` 只找两处——`.app` 根目录旁的 `MindBus_MindBus.bundle`
/// 与编译机上的绝对构建路径。发布包里资源包在 `Contents/Resources`（放根目录公证不过），
/// CI runner 的构建路径在用户机器上又不存在，两个候选全落空，`fatalError` 直接崩。
/// 本机 `install.sh` 装的能跑纯属巧合：兜底的绝对路径恰好是本机 `.build`。
///
/// 这里锁定的是「按发布包布局找资源包」这一步本身，以及 App 侧不再直接碰 `Bundle.module`。
final class ResourceBundleLocatorTests: XCTestCase {
    private var tmp: URL!

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MindBusCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rbl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// build-release.sh / install.sh 装出来的布局：
    /// `Foo.app/Contents/Resources/MindBus_MindBus.bundle/<平铺的资源文件>`
    func testFindsFlatBundleUnderContentsResources() throws {
        let resources = tmp.appendingPathComponent("Foo.app/Contents/Resources", isDirectory: true)
        let bundleDir = resources.appendingPathComponent("MindBus_MindBus.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: bundleDir.appendingPathComponent("menubar-logo.png"))

        let bundle = try XCTUnwrap(ResourceBundleLocator.bundled(named: "MindBus_MindBus", in: resources))
        XCTAssertEqual(bundle.bundleURL.resolvingSymlinksInPath().path,
                       bundleDir.resolvingSymlinksInPath().path)
        // SwiftPM 的资源包是平铺的（没有 Contents/），url(forResource:) 也必须找得到
        XCTAssertNotNil(bundle.url(forResource: "menubar-logo", withExtension: "png"))
    }

    func testReturnsNilWhenBundleMissingOrNoResourceDirectory() {
        XCTAssertNil(ResourceBundleLocator.bundled(named: "MindBus_MindBus", in: tmp))
        XCTAssertNil(ResourceBundleLocator.bundled(named: "MindBus_MindBus", in: nil))
    }

    /// 同名普通文件不算资源包
    func testIgnoresPlainFileWithBundleName() throws {
        try Data().write(to: tmp.appendingPathComponent("MindBus_MindBus.bundle"))
        XCTAssertNil(ResourceBundleLocator.bundled(named: "MindBus_MindBus", in: tmp))
    }

    /// 防回潮：App target 里只有 AppResources.swift 一处允许碰 `Bundle.module`（作兜底），
    /// 其余取资源一律走 `AppResources.bundle`。
    func testAppSourcesGoThroughAppResources() throws {
        let appDir = repositoryRoot.appendingPathComponent("MindBus")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if url.lastPathComponent == "AppResources.swift" { continue }
            // 只看代码行，注释里提到它不算
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("Bundle.module") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "改走 AppResources.bundle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appDir.appendingPathComponent("Config/AppResources.swift").path))
    }

    /// 两个组装脚本都必须在装完 bundle 后跑 `--check-resources` 自检——
    /// CI 跑测试时兜底路径恰好存在，只有这一步能证明「资源是从 .app 内部找到的」。
    func testPackagingScriptsRunResourceSelfCheck() throws {
        for script in ["scripts/build-release.sh", "scripts/install.sh"] {
            let src = try String(contentsOf: repositoryRoot.appendingPathComponent(script), encoding: .utf8)
            XCTAssertTrue(src.contains("--check-resources"), "\(script) 缺少资源自检")
        }
    }
}
