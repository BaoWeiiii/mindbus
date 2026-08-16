# Menu Bar Icon Optical Sizing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the approved Optical Reverse Fold menu-bar mark's real-screen optical mass while preserving its outer silhouette, fold language, logical status-item size, and interactions.

**Architecture:** Keep the 80×64 px template-image canvas and 20×16 pt AppKit image size unchanged. Update the pixel contract first, then make the deterministic renderer map the existing source silhouette from 76×52 px to 70×51 px and apply the identical affine transform to the approved fold. Regenerate the PNG, verify deterministic bytes, then build, install, and inspect the actual status item.

**Tech Stack:** Swift 5.9, AppKit, `NSBitmapImageRep`, Swift Package Manager, XCTest, ImageMagick for screenshot measurement.

---

## File Structure

- Modify `Tests/MindBusCoreTests/MenuBarIconResourceTests.swift`: lock the revised visible bounds and reduced nontransparent pixel mass.
- Modify `scripts/render-menubar-icon.swift`: centralize old/new silhouette geometry and transform both the source sampling rectangle and fold consistently.
- Regenerate `MindBus/Resources/menubar-logo.png`: deterministic black-and-alpha template image with the revised optical bounds.
- Do not modify `MindBus/StatusBarController.swift` or `Package.swift`; their existing 20×16 pt template-image integration remains the contract.

### Task 1: Lock the revised optical geometry with a failing test

**Files:**
- Modify: `Tests/MindBusCoreTests/MenuBarIconResourceTests.swift:45-55`
- Test: `Tests/MindBusCoreTests/MenuBarIconResourceTests.swift`

- [ ] **Step 1: Replace the existing geometry assertions with the revised contract**

Replace the final assertions in `testMenuBarIconIsBlackTemplateWithExpectedGeometry()` with:

```swift
        XCTAssertGreaterThan(nontransparentCount, 2_500)
        XCTAssertLessThan(nontransparentCount, 3_200)
        XCTAssertGreaterThan(partialAlphaCount, 100)
        XCTAssertEqual(minX, 5)
        XCTAssertEqual(minY, 6)
        XCTAssertEqual(maxX - minX + 1, 70)
        XCTAssertEqual(maxY - minY + 1, 51)
```

The upper pixel-count bound records the real-screen goal, not only the outer bounding box: the current asset contains 3,344 nontransparent pixels and must become optically lighter.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter MenuBarIconResourceTests/testMenuBarIconIsBlackTemplateWithExpectedGeometry
```

Expected: FAIL because the current asset has 3,344 nontransparent pixels and bounds `x: 2, y: 6, width: 76, height: 52`, while the test requires fewer than 3,200 pixels and bounds `x: 5, y: 6, width: 70, height: 51`.

- [ ] **Step 3: Commit the failing contract test**

```bash
git add Tests/MindBusCoreTests/MenuBarIconResourceTests.swift
git commit -m "test: tighten menu bar icon optical bounds"
```

### Task 2: Transform the renderer without redrawing the symbol

**Files:**
- Modify: `scripts/render-menubar-icon.swift:25-92`
- Modify: `scripts/render-menubar-icon.swift:135-162`
- Test: `Tests/MindBusCoreTests/MenuBarIconResourceTests.swift`

- [ ] **Step 1: Add explicit legacy and revised geometry constants**

Insert after `bilinearAlpha(...)` and before `strokeFold(...)`:

```swift
let legacySilhouetteBounds = CGRect(x: 2, y: 6, width: 76, height: 52)
let targetSilhouetteBounds = CGRect(x: 5, y: 6, width: 70, height: 51)

let foldScaleX = targetSilhouetteBounds.width / legacySilhouetteBounds.width
let foldScaleY = targetSilhouetteBounds.height / legacySilhouetteBounds.height
let foldStrokeScale = CGFloat(
    Darwin.sqrt(Double(foldScaleX * foldScaleY))
)

func transformFoldPoint(_ point: NSPoint) -> NSPoint {
    NSPoint(
        x: targetSilhouetteBounds.minX
            + (point.x - legacySilhouetteBounds.minX) * foldScaleX,
        y: targetSilhouetteBounds.minY
            + (point.y - legacySilhouetteBounds.minY) * foldScaleY
    )
}
```

- [ ] **Step 2: Apply the transform to every fold point and its stroke width**

Replace the path construction and width assignment inside `strokeFold(...)` with:

```swift
    let path = NSBezierPath()
    path.move(to: transformFoldPoint(NSPoint(x: 23.5, y: 18.0)))
    path.curve(
        to: transformFoldPoint(NSPoint(x: 36.7, y: 37.2)),
        controlPoint1: transformFoldPoint(NSPoint(x: 31.0, y: 24.8)),
        controlPoint2: transformFoldPoint(NSPoint(x: 34.8, y: 30.8))
    )
    if !lowerSegmentOnly {
        path.curve(
            to: transformFoldPoint(NSPoint(x: 50.8, y: 51.7)),
            controlPoint1: transformFoldPoint(NSPoint(x: 39.0, y: 43.9)),
            controlPoint2: transformFoldPoint(NSPoint(x: 43.2, y: 48.9))
        )
    }
    path.lineWidth = width * foldStrokeScale
```

Keep `path.lineCapStyle = .round`, `path.lineJoinStyle = .round`, and `path.stroke()` unchanged.

- [ ] **Step 3: Map the source silhouette into the revised integer-pixel bounds**

Replace the current `52 × 76` sampling loop with:

```swift
    let sourceWidth = maxX - minX + 1
    let sourceHeight = maxY - minY + 1
    let targetWidth = Int(targetSilhouetteBounds.width)
    let targetHeight = Int(targetSilhouetteBounds.height)
    let targetOriginX = Int(targetSilhouetteBounds.minX)
    let targetOriginY = Int(targetSilhouetteBounds.minY)

    for targetY in 0..<targetHeight {
        for targetX in 0..<targetWidth {
            let x = Double(minX)
                + (Double(targetX) + 0.5) * Double(sourceWidth) / Double(targetWidth)
                - 0.5
            let y = Double(minY)
                + (Double(targetY) + 0.5) * Double(sourceHeight) / Double(targetHeight)
                - 0.5
            let alpha = bilinearAlpha(
                source,
                x: x,
                y: y,
                bounds: (minX, minY, maxX, maxY)
            )
            writeBlack(
                alpha: alpha,
                x: targetX + targetOriginX,
                y: targetY + targetOriginY
            )
        }
    }
```

Keep the two existing `strokeFold(...)` calls and their alpha values unchanged. Only their geometry and widths change through the shared transform.

- [ ] **Step 4: Regenerate the production asset**

Run:

```bash
swift scripts/render-menubar-icon.swift \
  MindBus/Resources/logo.png \
  MindBus/Resources/menubar-logo.png
```

Expected: exit 0 and a regenerated 80×64 RGBA PNG.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
swift test --filter MenuBarIconResourceTests
```

Expected: 2 tests pass with 0 failures. This covers pixel dimensions, black-only template pixels, partial-alpha fold pixels, revised visible bounds, reduced optical mass, resource bundling, logical image size, template behavior, and accessibility labeling.

- [ ] **Step 6: Verify deterministic output**

Run the renderer twice into separate temporary files:

```bash
swift scripts/render-menubar-icon.swift MindBus/Resources/logo.png /private/tmp/mindbus-menubar-a.png
swift scripts/render-menubar-icon.swift MindBus/Resources/logo.png /private/tmp/mindbus-menubar-b.png
shasum -a 256 MindBus/Resources/menubar-logo.png /private/tmp/mindbus-menubar-a.png /private/tmp/mindbus-menubar-b.png
```

Expected: all three printed SHA-256 values are identical.

- [ ] **Step 7: Commit the renderer and generated asset**

```bash
git add scripts/render-menubar-icon.swift MindBus/Resources/menubar-logo.png
git commit -m "fix: rebalance menu bar icon optical size"
```

### Task 3: Verify, install, and inspect the real status item

**Files:**
- Verify: `MindBus/Resources/menubar-logo.png`
- Verify: `/Applications/MindBus.app/MindBus_MindBus.bundle/menubar-logo.png`

- [ ] **Step 1: Run the complete test suite**

Run:

```bash
swift test
```

Expected: all tests pass with 0 failures.

- [ ] **Step 2: Build the application product**

Run:

```bash
swift build --product MindBus
```

Expected: `Build of product 'MindBus' complete!` and exit 0.

- [ ] **Step 3: Install and relaunch the application**

Run:

```bash
./scripts/install.sh
```

Expected: release build succeeds, `/Applications/MindBus.app` is replaced, and MindBus relaunches from the installed bundle.

- [ ] **Step 4: Confirm the installed resource matches the repository asset**

Run:

```bash
shasum -a 256 \
  MindBus/Resources/menubar-logo.png \
  /Applications/MindBus.app/MindBus_MindBus.bundle/menubar-logo.png
```

Expected: both SHA-256 values are identical.

- [ ] **Step 5: Capture and measure the real menu bar**

Use Computer Use, after the user grants screen-recording permission, to capture the running MindBus status item. In the persistent Node REPL, fetch the state and save its screenshot with:

```javascript
if (!globalThis.sky) globalThis.sky = (await import("@oai/sky")).sky;
var liveMindBusState = await sky.get_app_state({ app: "MindBus", disableDiff: true });
var liveFs = await import("node:fs/promises");
var liveUrl = await import("node:url");
if (!liveMindBusState.screenshot) throw new Error("MindBus screenshot unavailable");
await liveFs.copyFile(
    liveUrl.fileURLToPath(liveMindBusState.screenshot.url),
    "/private/tmp/mindbus-menubar-live.png"
);
```

Crop the status-item neighborhood and measure it with:

```bash
magick /private/tmp/mindbus-menubar-live.png \
  -colorspace gray -threshold 20% \
  -define connected-components:verbose=true \
  -connected-components 8 null:
```

Expected on a 2× display: approximately 35×25–26 px, vertically centered with neighboring symbols, retaining the lower-left to upper-right soft fold, and visibly lighter than the previous 38×26 px capture.

- [ ] **Step 6: Verify interactions**

Use Computer Use to left-click the MindBus status item and confirm the tray popover opens. Close it, right-click the same item, and confirm the context menu opens. Do not select destructive menu actions.

- [ ] **Step 7: Review final repository state**

Run:

```bash
git status --short
git log -3 --oneline
```

Expected: no uncommitted implementation changes remain, and the latest commits are the focused test contract and renderer/asset update.
