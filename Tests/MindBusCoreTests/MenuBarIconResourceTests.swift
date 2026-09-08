import AppKit
import XCTest

final class MenuBarIconResourceTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MindBusCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    func testMenuBarIconIsBlackTemplateWithExpectedGeometry() throws {
        let iconURL = repositoryRoot
            .appendingPathComponent("MindBus/Resources/menubar-logo.png")
        let data = try Data(contentsOf: iconURL)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))

        XCTAssertEqual(image.pixelsWide, 80)
        XCTAssertEqual(image.pixelsHigh, 64)

        var minX = image.pixelsWide
        var minY = image.pixelsHigh
        var maxX = -1
        var maxY = -1
        var nontransparentCount = 0
        var partialAlphaCount = 0

        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let color = try XCTUnwrap(
                    image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                )
                let alpha = color.alphaComponent
                if alpha <= 1.0 / 255.0 { continue }

                nontransparentCount += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)

                XCTAssertLessThanOrEqual(color.redComponent, 1.0 / 255.0)
                XCTAssertLessThanOrEqual(color.greenComponent, 1.0 / 255.0)
                XCTAssertLessThanOrEqual(color.blueComponent, 1.0 / 255.0)
                if alpha < 254.0 / 255.0 { partialAlphaCount += 1 }
            }
        }

        XCTAssertGreaterThan(nontransparentCount, 1_500)
        XCTAssertGreaterThan(partialAlphaCount, 100)
        XCTAssertEqual(minX, 2)
        XCTAssertEqual(minY, 6)
        XCTAssertEqual(maxX - minX + 1, 76)
        XCTAssertEqual(maxY - minY + 1, 52)
    }

    func testAppBundlesAndLoadsMenuBarIconAsTemplate() throws {
        let packageSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("MindBus/StatusBarController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(packageSource.contains(#".copy("Resources/menubar-logo.png")"#))
        XCTAssertTrue(controllerSource.contains(#"url(forResource: "menubar-logo", withExtension: "png")"#))
        XCTAssertTrue(controllerSource.contains("image.size = NSSize(width: 20, height: 16)"))
        XCTAssertTrue(controllerSource.contains("image.isTemplate = true"))
        XCTAssertTrue(controllerSource.contains(#"button.setAccessibilityLabel("MindBus")"#))
    }
}
